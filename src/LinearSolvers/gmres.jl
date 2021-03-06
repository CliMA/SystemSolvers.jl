
export GeneralizedMinimalResidualMethod


"""
    GeneralizedMinimalResidualMethod(; M=30, K=10)

# GMRES
This object represents an iterative Krylov method for solving a linear system.
The constructor parameter `M` is the number of steps after which the algorithm
is restarted (if it has not converged), `K` is the maximal number of restarts.
The amount of memory required for the solver state is roughly `(M + 1) * N`, where `N`
is the number of unknowns. This uses the restarted Generalized Minimal
Residual method of Saad and Schultz (1986).

## References
    @article{saad1986gmres,
      title={GMRES: A generalized minimal residual algorithm for solving nonsymmetric linear systems},
      author={Saad, Youcef and Schultz, Martin H},
      journal={SIAM Journal on scientific and statistical computing},
      volume={7},
      number={3},
      pages={856--869},
      year={1986},
      publisher={SIAM}
    }
"""
struct GeneralizedMinimalResidualMethod <: AbstractKrylovMethod
    "Maximum number of Krylov iterations"
    M::Int
    "Maximum number of restarts"
    K::Int
    function GeneralizedMinimalResidualMethod(; M=30, K=10)
        return new(M, K)
    end
end

mutable struct GMRESCache{M, MP1, MMP1, T, AT} <: AbstractLinearSolverCache
    krylov_basis::NTuple{MP1, AT}
    "Hessenberg matrix"
    H::Matrix{T}
    "rhs of the least squares problem"
    g0::Vector{T}
    "work vector for preconditioning"
    Wvec::AT
end

function cache(
    krylov_alg::GeneralizedMinimalResidualMethod,
    Q::AT,
) where {AT}
    Wvec = similar(Q)
    M = krylov_alg.M
    krylov_basis = ntuple(i -> similar(Q), M + 1)
    FT = eltype(Q)
    H = zeros(M + 1, M)
    g0 = zeros(M + 1)

    return GMRESCache{M, M + 1, M * (M + 1), eltype(Q), AT}(
        krylov_basis,
        H,
        g0,
        Wvec,
    )
end

function LSinitialize!(
    ::GeneralizedMinimalResidualMethod,
    solver::LinearSolver,
    Q,
    Qrhs,
    args...,
)
    linearoperator! = solver.linop!
    pc = solver.pc

    cache = solver.cache
    g0 = cache.g0
    krylov_basis = cache.krylov_basis
    atol = solver.atol

    @assert size(Q) == size(krylov_basis[1])

    # store the initial residual in krylov_basis[1]
    linearoperator!(krylov_basis[1], Q, args...)
    @. krylov_basis[1] = Qrhs - krylov_basis[1]

    # apply left preconditioning
    if isa(pc.pc_side, PCleft)
        PCapply!(pc, cache.Wvec, krylov_basis[1], args...)
        @. krylov_basis[1] = cache.Wvec
    end

    residual_norm = norm(krylov_basis[1])
    threshold = solver.rtol * residual_norm

    converged = false
    if threshold < solver.atol
        converged = true
        return converged, threshold
    end

    fill!(g0, 0)
    g0[1] = residual_norm
    krylov_basis[1] ./= residual_norm

    converged, max(threshold, atol)
end

function LSsolve!(
    krylov_alg::GeneralizedMinimalResidualMethod,
    solver::LinearSolver,
    threshold,
    Q,
    Qrhs,
    args...,
)
    converged = false
    iter = 0
    total_iters = 0
    residual_norm = typemax(eltype(Q))

    while !converged && iter < krylov_alg.K
        converged, cycle_iters, residual_norm = gmres_cycle!(solver, threshold, Q, Qrhs, args...)

        iter += 1
        total_iters += cycle_iters

        # If we blow up, we want to know about it
        if !isfinite(residual_norm)
            error("norm of residual is not finite after $total_iters iterations.")
        end
    end

    (converged, total_iters, residual_norm)
end

function gmres_cycle!(
    solver::LinearSolver,
    threshold,
    Q,
    Qrhs,
    args...,
)
    linearoperator! = solver.linop!
    pc = solver.pc
    cache = solver.cache
    krylov_basis = cache.krylov_basis
    H = cache.H
    g0 = cache.g0
    rtol = solver.rtol
    atol = solver.atol

    converged = false
    residual_norm = typemax(eltype(Q))
    Ω = LinearAlgebra.Rotation{eltype(Q)}([])
    j = 1
    for outer j in 1:solver.krylov_alg.M
        # apply right preconditioning
        if isa(pc.pc_side, PCright)
            PCapply!(pc, cache.Wvec, krylov_basis[j], args...)
            @. krylov_basis[j] = cache.Wvec
        end

        # apply the linear operator
        linearoperator!(krylov_basis[j + 1], krylov_basis[j], args...)

        # apply left preconditioning
        if isa(pc.pc_side, PCleft)
            PCapply!(pc, cache.Wvec, krylov_basis[j + 1], args...)
            @. krylov_basis[j + 1] = cache.Wvec
        end

        # Arnoldi using the Modified Gram Schmidt orthonormalization
        for i in 1:j
            H[i, j] = dot(krylov_basis[j + 1], krylov_basis[i])
            @. krylov_basis[j + 1] -= H[i, j] * krylov_basis[i]
        end
        H[j + 1, j] = norm(krylov_basis[j + 1])
        krylov_basis[j + 1] ./= H[j + 1, j]

        # apply the previous Givens rotations to the new column of H
        @views H[1:j, j:j] .= Ω * H[1:j, j:j]

        # compute a new Givens rotation to zero out H[j + 1, j]
        G, _ = givens(H, j, j + 1, j)

        # apply the new rotation to H and the rhs
        H .= G * H
        g0 .= G * g0

        # compose the new rotation with the others
        Ω = lmul!(G, Ω)

        residual_norm = abs(g0[j + 1])

        if residual_norm < threshold
            converged = true
            break
        end
    end

    # solve the triangular system
    # The commented-out version occasionally introduces a ~150% increase in
    # allocations and a ~5% increase in time. When combined with the commented-
    # out kernel abstraction code below, this becomes a ~800% increase in
    # allocations and a ~200% increase in time.
    # y = NTuple{j}(@views UpperTriangular(H[1:j, 1:j]) \ g0[1:j])
    y = @views UpperTriangular(H[1:j, 1:j]) \ g0[1:j]

    # compose the solution
    # The commented-out version occasionally introduces a ~100% increase in time
    # without any increase in allocations. When combined with the commented-out
    # code above, this becomes a ~800% increase in allocations and a ~200%
    # increase in time.
    # rv_Q = realview(Q)
    # rv_krylov_basis = realview.(krylov_basis)
    # groupsize = 256
    # event = Event(array_device(Q))
    # event = linearcombination!(array_device(Q), groupsize)(
    #     rv_Q,
    #     y,
    #     rv_krylov_basis,
    #     true;
    #     ndrange = length(rv_Q),
    #     dependencies = (event,),
    # )
    # wait(array_device(Q), event)
    for i in 1:j
        @. Q += y[i] * krylov_basis[i]
    end

    # unwind right-preconditioning
    if isa(pc.pc_side, PCright)
        PCapply!(pc, cache.Wvec, Q, args...)
        @. Q = cache.Wvec
    end

    # If not converged, restart by reinitializing with current Q
    converged || LSinitialize!(solver, Q, Qrhs, args...)
    (converged, j, residual_norm)
end
