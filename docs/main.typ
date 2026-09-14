#import "@preview/clean-math-paper:0.1.0": *

#let date = datetime.today().display("[month repr:long] [day], [year]")
#show: template.with(
  title: "Artelys Knitro in PowSyBl Open Load Flow: a Resilient Optimization-Based AC Load Flow",
  authors: (
    (name: "Salomé Lavine", affiliation-id: 1),
    (name: "Amine Makhen", affiliation-id: 1),
    (name: "Jeanne Archambault", affiliation-id: 1),
    (name: "Pierre Arvy", affiliation-id: 1),
    (name: "Martin Debouté", affiliation-id: 1),
    (name: "Hadrien Godard", affiliation-id: 1),
  ),
  affiliations: (
    (id: 1, name: "Artelys, Paris"),
  ),
  date: date,
  heading-color: rgb("#2e44a6"),
  link-color: rgb("#12472b"),
  abstract: [We present a resilient optimization-based formulation of the AC load flow problem, implemented with Artelys Knitro inside the open-source PowSyBl (Power System Blocks) framework. Unlike the classical Newton-Raphson method, which may fail on ill-conditioned or infeasible cases without explaining why, our approach introduces bounded-sign slack variables on the active power, reactive power and target-voltage equations, and penalizes them in the objective. The retained penalty is a *pure $ell_1$ norm*: it is exact, it keeps the objective linear in the slacks, and it removes the structural incentive to spread a violation over many buses, which is what makes the returned solution diagnosable. We then derive a physically grounded methodology to set the three remaining weights $(omega_P, omega_Q, omega_V)$ from business quantities: a reactive anchor, an MW/MVAr equivalence driven by the DC active imbalance, and a kV/MVAr equivalence driven by the short-circuit power at the bus. The model was validated through stress tests on IEEE networks with controlled perturbations, and on real data. Where Newton-Raphson fails to converge, the proposed model consistently returns feasible, physically interpretable solutions whose active slacks localize the inconsistency.],
  keywords: ("Operations Research", "AC Load Flow", "Nonlinear Programming", "Exact Penalty"),
)

#set math.equation(numbering: "(1)")

= Introduction

Solving the load flow and the Optimal Power Flow (OPF) problems is vital to guarantee the security and the efficiency of modern power systems. The OPF ensures that all operational limits --- voltage, line flow, generator capacity --- are respected, thus maintaining system stability and preventing violations that could lead to breakdowns or equipment damage. It also provides valuable insight for sensitivity analyses, helping operators understand how changes in system conditions, such as demand fluctuations or the integration of renewable energy sources, affect network performance.

Newton-Raphson is the reference numerical algorithm to solve the load flow equations. It is fast and robust on well-posed cases, but it suffers from two practical limitations on real data:

+ when the data are inconsistent (conflicting voltage setpoints, unrealistic active imbalance after a merging process, erroneous shunt sections), the underlying square system is simply *infeasible* and no iterative scheme can converge;
+ when it fails, it returns a divergence flag and nothing else: the user has no indication of *where* the problem is.

This work investigates a different route: reformulating the load flow as a nonlinear optimization problem, solved with Artelys Knitro, in which infeasibility is absorbed by explicit slack variables. The solution is then always available, and the set of non-zero slacks acts as a diagnosis of the dataset.

The document is organized as follows. @sec:formalism recalls the physical and mathematical formalism and the reference square formulation. @sec:model presents the resilient model, discusses the choice of the penalty function and justifies the retained pure $ell_1$ form. @sec:calibration derives the weight-setting methodology, which is a direct consequence of that choice. @sec:implementation and @sec:validation describe the implementation and the validation protocol.

= Formalism <sec:formalism>

== Mathematical representation of power systems

The physical electrical network is approximated by a mathematical model, represented as an undirected graph $cal(G)$, where nodes model important locations of the actual grid (generation points, load points), and where edges model the behavior of electrical lines, such as resistance and reactance effects.

Nodes are named *buses*. At every bus $k in cal(N)$, we denote by $v_k = abs(V_k) e^(j theta_k)$ the complex voltage, with $V_k$ and $theta_k$ the unknown voltage magnitude and angle. These two quantities are determined by solving the power flow equations defined in @sec:pfeq.

A generator (production) or a load (consumption) can be linked to a bus, thus setting a production or consumption target at this bus. All buses with a voltage-regulating generator are referred to as *PV buses*, the others as *PQ buses*. For simplicity, we consider that a bus is either PV or PQ. At a PV bus, the active power $P$ and the voltage magnitude $V$ are specified; at a PQ bus, the active power $P$ and the reactive power $Q$ are specified. We denote by $cal(N)_"PV"$ and $cal(N)_"PQ"$ the corresponding sets, with $cal(N)_"PV" union cal(N)_"PQ" =: cal(N)$.

Edges link two buses and represent an electrical branch with its parameters. We denote by $cal(E)$ the set of edges, and by $"Ngh"(i)$ the set of buses adjacent to $i$.

== $Pi$ model of a branch

Let $i, j in cal(N)$. A commonly adopted model to represent a transmission line or a branch linking two buses is the $Pi$ model: a series impedance and two shunt admittances, one at each end of the series impedance.

#figure(
  image("misc/pi_model.png"),
  caption: [$Pi$ model of a transmission line],
)

We denote by:

- $Z_(i j) = R_(i j) + j X_(i j)$ the complex impedance, representing the resistance and the reactance of the line, connected in series. The resistance accounts for the real power loss in the conductor; the reactance is associated with the magnetic field surrounding the conductor.

- $G_(i j)$ (resp. $G_(j i)$) the conductance and $B_(i j)$ (resp. $B_(j i)$) the susceptance on side $i$ (resp. side $j$). They represent the real power loss caused by current leakage --- currents flowing to the ground --- and by corona discharge.

- $rho_(i j)$ the magnitude ratio and $alpha_(i j)$ the phase shift between side $j$ and side $i$, which together form a transformer. Transformers control magnitudes and phases, and through them, power. By default there is no transformer on a branch, hence $rho_(i j) = 1$ and $alpha_(i j) = 0$; in that case the branch is a line, linking buses at the same voltage level. Otherwise it is a transformer.

The active and reactive powers flowing from bus $i$ to bus $j$ are given by the following nonlinear, non-convex expressions:

$ p_(i j) (V, theta) := rho_(i j) V_i V_j Y_(i j) sin(theta_i - theta_j + alpha_(i j) - Xi_(i j)) + rho_(i j)^2 V_i^2 (G_(i j) + Y_(j i) sin(Xi_(i j))) $ <eq:pflow>

$ q_(i j) (V, theta) := -rho_(i j) V_i V_j Y_(i j) cos(theta_i - theta_j + alpha_(i j) - Xi_(i j)) + rho_(i j)^2 V_i^2 (-B_(i j) + Y_(j i) cos(Xi_(i j))) $ <eq:qflow>

where $R + j X = 1/Y_(i j) e^(j(pi/2 - Xi_(i j)))$.

== Power flow equations <sec:pfeq>

We arbitrarily designate a generator bus as the *slack bus*, denoted $s in cal(N)$. The slack bus maintains the overall active power balance: $P$ is not specified there, which makes it able to absorb any imbalance between production and consumption inherent to the network (including the power dissipated by the Joule effect).

Removing the equation in $P$ would make the system under-determined, since the slack bus would only carry its magnitude equation. Instead of setting $P$ at this bus, we fully set the voltage by also fixing the phase. Since the power equations @eq:pflow and @eq:qflow only depend on phase *differences*, the phase at the slack bus can be set to zero; every other bus voltage is then expressed relative to the slack bus.

The system is then fully determined:

- at every bus $i in cal(N)$ there are two unknowns, $V_i$ and $theta_i$, hence $2 times abs(cal(N))$ variables;
- we therefore need $2 times abs(cal(N))$ non-redundant equations.

At the slack bus $s$:

$ theta_s = 0, quad quad V_s = V_s^"ref" $

At PV buses, $forall i in cal(N)_"PV" without {s}$:

$ P_i = sum_(j in "Ngh"(i)) p_(i j)(V, theta), quad quad V_i = V_i^"ref" $

At PQ buses, $forall i in cal(N)_"PQ"$:

$ P_i = sum_(j in "Ngh"(i)) p_(i j)(V, theta), quad quad Q_i = sum_(j in "Ngh"(i)) q_(i j)(V, theta) $

Equations in $V$ are called *target $V$* equations, setting the operating target of PV buses. Equations in $P$ and $Q$ are *flow conservation* constraints, maintaining injection equilibrium at every bus. Together they form a $2 times abs(cal(N))$ nonlinear, non-convex system, commonly called the *power flow equations*.

== Reference (square) formulation

For the sake of clarity, the reference model solved by Newton-Raphson can be written as a feasibility problem with a null objective:

$
min_(V, theta) quad & 0 \
"s.t." quad & P_i - sum_(j in "Ngh"(i)) p_(i j)(V, theta) = 0, quad & forall i in cal(N) without {s} \
& Q_i - sum_(j in "Ngh"(i)) q_(i j)(V, theta) = 0, quad & forall i in cal(N)_"PQ" \
& V_i - V_i^"ref" = 0, quad & forall i in cal(N)_"PV" \
& theta_s = 0 \
& V_i, theta_i in RR, quad & forall i in cal(N)
$ <eq:historical>

This formulation has *no* degree of freedom: either the system admits a solution, or the solver fails.

== Nomenclature

#figure(
  table(
    columns: (auto, auto),
    inset: 7pt,
    align: (left, left),
    table.header([*Symbol*], [*Meaning*]),
    [$cal(N)$, $cal(E)$], [sets of buses and branches],
    [$cal(N)_"PV"$, $cal(N)_"PQ"$], [PV (voltage-regulating) and PQ buses],
    [$s$], [slack bus],
    [$V_i$, $theta_i$], [voltage magnitude (p.u.) and angle (rad) at bus $i$],
    [$p_(i j)$, $q_(i j)$], [active / reactive flow from $i$ to $j$, see @eq:pflow and @eq:qflow],
    [$s_(P_i)^plus.minus$, $s_(Q_i)^plus.minus$, $s_(V_i)^plus.minus$], [non-negative slacks on the $P$, $Q$ and target-$V$ equations],
    [$omega_P$, $omega_Q$, $omega_V$], [penalty weights of the objective],
    [$S_"base"$], [power base, 100 MVA],
    [$S_"cc"$, $I_"cc"$], [short-circuit power / current at a bus],
    [$gamma$], [voltage stiffness, $gamma = S_"cc" \/ S_"base"$],
    [$rho_(P Q)$], [MW/MVAr equivalence ratio],
    [$eta$], [voltage de-prioritization factor],
  ),
  caption: [Main notation.],
) <tab:nomenclature>

= The resilient model <sec:model>

== Principle: relaxing with signed slacks

The idea is to add slack variables on the $P$, $Q$ and target-$V$ equations so that the feasible set is never empty, and to penalize these variables in the objective so that they stay at zero whenever the physical problem admits a solution.

Each equation $c(V, theta) = 0$ becomes $c(V, theta) - s^+ + s^- = 0$ with $s^+, s^- >= 0$, so that the residual is $epsilon = s^+ - s^-$ and its absolute value is $s^+ + s^-$ *provided* that $s^+ s^- = 0$. This complementarity does not need to be imposed: with any penalty that is increasing in $s^+ + s^-$, subtracting $min(s^+, s^-)$ from both variables keeps the point feasible and strictly decreases the objective, so any optimal solution satisfies $min(s^+, s^-) = 0$.

== Choice of the penalty function

Let $epsilon$ denote the residual of a relaxed equation. Three candidates were considered.

*Quadratic ($ell_2$), $h(epsilon) = epsilon^2$.* Smooth and easy for the solver, but it *diffuses*: since the cost is strictly convex, spreading a total violation $S$ over $n$ buses costs $n dot (S\/n)^2 = S^2\/n$, which strictly decreases with $n$. The solver therefore prefers to smear an inconsistency over the whole network rather than expose it where it is. This destroys the diagnostic value of the slacks, which is the main purpose of the model, and it does so *independently of the weights* $omega$.

*Huber.* The historical model used an adaptive Huber-type loss, quadratic near zero and linear beyond a threshold $tau$, augmented with a kink at the origin to avoid a vanishing marginal penalty for small residuals:

$
h(epsilon) := cases(
  1/2 epsilon^2 + lambda abs(epsilon) quad quad quad space "if" abs(epsilon) <= tau",",
  tau (abs(epsilon) - 1/2 tau) + lambda abs(epsilon) quad "otherwise."
)
$

#figure(
  image("misc/huber_loss.png"),
  caption: [Huber's loss function (quadratic near the origin, linear beyond $tau$).],
)

It requires the calibration of one threshold $tau$ per constraint type, in addition to the weights, and it retains the diffusive behaviour in the quadratic regime.

*Mixed $ell_2 + ell_1$.* The model that was actually implemented used $h(epsilon) = mu epsilon^2 + lambda abs(epsilon)$ with $mu = 1$, $lambda = 3$ and unit weights. The marginal cost of the $ell_2$ term, $2 mu epsilon$, equals that of the $ell_1$ term, $lambda$, at

$ epsilon^* = lambda / (2 mu) = 1.5 " p.u." = 150 " MW" quad (S_"base" = 100 " MVA"). $

In other words, on the whole range of realistic violations, *the implemented penalty was already behaving like an $ell_1$ norm*: the quadratic term only took over beyond 150 MW, exactly in the regime where diffusion is most harmful.

*Retained choice: pure $ell_1$.* We therefore drop the quadratic term entirely and keep

$ h(s^+, s^-) = s^+ + s^-. $ <eq:penalty>

This formalizes the behaviour the model already had in the useful range, and removes the diffusion mechanism in the large-violation range. It has four further consequences that structure the rest of this document.

+ *Exactness.* The $ell_1$ penalty is an exact penalty function: for weights above the magnitude of the optimal multipliers, the relaxed problem and the original one share the same solutions. Here the property is even stronger, see @sec:inert.

+ *Linearity.* With the $s^+ \/ s^-$ splitting, the objective is *linear*. The nonlinearity and non-convexity of the problem are entirely carried by the flow equations; the Hessian of the Lagrangian comes only from the constraints, which is numerically favorable for an interior-point or SQP method.

+ *No incentive to diffuse.* With an $ell_1$ norm, distributing a given total violation over $n$ buses costs the same as concentrating it on one. The penalty is neutral, and the arbitration is left to the physics: spreading an imbalance over electrically distant buses requires additional transits, hence additional losses and additional residuals elsewhere. In practice, the solver concentrates. This is the classical argument behind $ell_1$ relaxations of cardinality objectives --- the $ell_1$ norm is the convex envelope of $ell_0$ on bounded sets --- and it is what makes the solution *readable*: a short list of non-zero slacks pointing at the faulty data.

+ *Only ratios matter.* Scaling all weights by the same positive constant leaves the argmin unchanged. The calibration problem is therefore two-dimensional, not three-dimensional: one weight can be fixed by convention and the other two are *relative prices*.

*Numerical note.* The objective being linear in the slacks, the problem is degenerate by construction: several slack distributions may share the same optimal cost. If this turns out to hinder convergence or reproducibility, a vanishing quadratic regularization $epsilon sum (s^+ - s^-)^2$ with $epsilon$ several orders of magnitude below the smallest weight can be added to select a unique solution without reintroducing the diffusion effect.

== The optimization model

Using @eq:penalty, the resilient AC load flow is the following nonlinear program:

$
min_(V, theta, s^plus.minus) quad
& omega_P sum_(i in cal(N) without {s}) (s_(P_i)^+ + s_(P_i)^-)
 + omega_Q sum_(i in cal(N)_"PQ") (s_(Q_i)^+ + s_(Q_i)^-)
 + omega_V sum_(i in cal(N)_"PV") (s_(V_i)^+ + s_(V_i)^-) \
"s.t." quad
& sum_(j in "Ngh"(i)) p_(i j)(V, theta) - P_i^"ref" - s_(P_i)^+ + s_(P_i)^- = 0, quad & forall i in cal(N) without {s} \
& sum_(j in "Ngh"(i)) q_(i j)(V, theta) - Q_i^"ref" - s_(Q_i)^+ + s_(Q_i)^- = 0, quad & forall i in cal(N)_"PQ" \
& V_i - V_i^"ref" - s_(V_i)^+ + s_(V_i)^- = 0, quad & forall i in cal(N)_"PV" \
& theta_s = 0 \
& 0.5 <= V_i <= 1.5, quad & forall i in cal(N) \
& s_(P_i)^+, s_(P_i)^- >= 0, quad & forall i in cal(N) without {s} \
& s_(Q_i)^+, s_(Q_i)^- >= 0, quad & forall i in cal(N)_"PQ" \
& s_(V_i)^+, s_(V_i)^- >= 0, quad & forall i in cal(N)_"PV" \
& theta_i in RR, quad & forall i in cal(N)
$ <eq:model>

Compared with the historical formulation @eq:historical, the feasible set is never empty: any $(V, theta)$ satisfying the bounds can be completed by slacks. The solver therefore always returns a point, and the question becomes the *quality* and the *interpretability* of that point.

== The weights are inert on healthy networks <sec:inert>

The objective of @eq:model is non-negative and vanishes if and only if all slacks are zero, that is, if and only if $(V, theta)$ solves the original power flow equations. Consequently:

#block(
  inset: 8pt,
  radius: 3pt,
  fill: luma(245),
  width: 100%,
)[
  *If the load flow problem is feasible, then for any strictly positive weights the global optima of @eq:model are exactly the solutions of the original system @eq:historical.*
]

The weights play *no role* on well-posed cases: they cannot bias the result, only the numerical path towards it. They matter only when the data are inconsistent, where they arbitrate *which* equation is relaxed and by how much. Two practical consequences:

- a non-regression benchmark on healthy networks validates the implementation and the numerics, but says nothing about the calibration;
- the calibration must be evaluated on the perturbed instances of @sec:validation, by looking at *where* the slacks land, not at the objective value.

== Discarded alternative: normalization by tolerances

An alternative discussed during the study was to normalize each slack by a characteristic tolerance $delta_P$, $delta_Q$, $delta_V$ representing an operationally acceptable deviation, making the objective dimensionless, e.g. 5% for active power, 10% for reactive power, 1% for voltage. Under a pure $ell_1$ penalty, this is not an alternative but a *reparametrization*: dividing the slack by $delta_t$ is exactly equivalent to setting $omega_t = 1 \/ delta_t$. The methodology of @sec:calibration can therefore be read either way, as a choice of relative prices or as a choice of tolerances; we keep the weights formulation because the physical derivations below produce prices directly.

= Setting the objective weights <sec:calibration>

Because the retained penalty is a pure $ell_1$ norm, the objective is a *linear price system*: $omega_t$ is the cost of one per-unit of violation of a constraint of type $t$, and only the ratios between the three prices matter. The calibration is therefore organized as a cascade starting from a single anchor.

== Step 1: anchor --- reactive weight

We fix the reactive weight as the reference. It represents the cost of one MVAr of deviation, expressed in objective units:

$ omega_Q := 1 quad ("by convention") $ <eq:anchor>

Every other quantity is expressed relative to this anchor. Any other value would give the same optimal solutions, by the scale invariance noted above.

== Step 2: active weight --- MW/MVAr equivalence

The weight $omega_P$ expresses how many MVAr of deviation one MW of deviation is "worth". We write it as an equivalence ratio $rho_(P Q)$:

$ omega_P = rho_(P Q) dot omega_Q = rho_(P Q) $ <eq:omega_p>

The ratio is modulated by the *global active imbalance* of the case, computed before solving under DC assumptions:

$ Delta_P = sum P_"gen" - sum P_"load" - hat(L) $ <eq:delta_p>

where $hat(L)$ estimates the losses. A first approximation is $hat(L) approx alpha sum P_"load"$ with $alpha approx 2%$--$3%$. More precisely, under DC assumptions the active transit on line $(i,j)$ is $P_(i j)^"DC" = (theta_i - theta_j) \/ x_(i j)$ in p.u., and the Joule losses on that line, with $abs(I) = P_(i j)^"DC" \/ V$, are

$ L_(i j) = r_(i j) (P_(i j)^"DC")^2 / V^2 approx r_(i j) (P_(i j)^"DC")^2 $

the last approximation holding for $V approx 1$ p.u. Total losses are $hat(L) = sum_((i,j) in cal(E)) L_(i j)$.

We choose $rho_(P Q)$ inversely proportional to $abs(Delta_P)$: the better the active balance of the dataset, the more suspicious a residual active slack is, hence the more it should be penalized. Conversely, a case that is grossly unbalanced --- typically after merging national networks with inconsistent border exchanges --- *has* to place active slacks somewhere, and forcing them to be expensive would only push the infeasibility onto the voltage targets. With $P = sum P_"gen"$ the total generation:

$ rho_(P Q) = min(max(P / (10 abs(Delta_P)), rho_min), rho_max), quad rho_min = 10, quad rho_max = 1000 $ <eq:rho>

The ratio exceeds 10 as soon as $abs(Delta_P) < P \/ 100$, i.e. as soon as the imbalance is below 1% of the generation. The floor $rho_min$ guarantees that active deviations always remain at least an order of magnitude more expensive than reactive ones; the cap $rho_max$ avoids a degenerate price when $Delta_P arrow.r 0$ and keeps the objective well scaled.

The form and the bounds of @eq:rho are heuristic; near balance, its sensitivity is dominated by the error on $hat(L)$, and the calibration is addressed in the experimental protocol of @sec:protocol.

== Step 3: voltage weight --- kV/MVAr equivalence

The physical link between voltage and reactive power is given by the sensitivity of a bus connected to the rest of the network through an equivalent impedance. Consider a bus at voltage $V$ connected to a voltage source $E$ (the rest of the network) through an impedance $Z = R + j X$. The apparent power injected at the bus is

$ S = V dot I^* = V ((E - V) / Z)^* $

In polar coordinates ($V = V angle delta$, $E = E angle 0$), the reactive power reads

$ Q = (V E cos delta - V^2) / X - (V E sin delta) / R $

On a transmission network, $R << X$ (the $R\/X$ ratio is typically of the order of $0.1$) and angle deviations are small ($cos delta approx 1$, $sin delta approx 0$), so

$ Q approx (V (V - E)) / X $

Differentiating around the operating point ($V approx E approx V_"nom"$):

$ Delta Q approx (V_"nom" Delta V) / X quad ==> quad (Delta V) / V_"nom" approx (Delta Q dot X) / V_"nom"^2 $

The sensitivity of voltage to reactive power is inversely proportional to the *stiffness* of the network. In per-unit, this defines

$ gamma := V_"nom"^2 / (X dot S_"base") = 1 / X_"p.u.", quad quad "so that" quad s_V^"p.u." = s_Q^"p.u." / gamma $ <eq:gamma>

Two ways of estimating $gamma$ were considered.

*Approach 1 --- typical reactance.* The linear reactance of a 400 kV overhead line is of the order of $x_l approx 0.3 space Omega\/"km"$. For a length $L approx 150$ km (order of magnitude of an inter-substation 400 kV link in mainland France), $X_"line" = 0.3 times 150 = 45 space Omega$. With $Z_"base" = V_"nom"^2 \/ S_"base" = 400^2 \/ 100 = 1600 space Omega$, we get $X_"p.u." approx 0.03$ and $gamma approx 33$. This estimate is crude: it accounts for a single line, ignoring both the number of lines connected to the bus and the network beyond the first neighborhood.

*Approach 2 --- short-circuit power (recommended).* The three-phase short-circuit current is $I_"cc" = V_"nom" \/ (sqrt(3) X)$ (phase-to-neutral voltage over the Thévenin impedance, under $R << X$), hence $S_"cc" = sqrt(3) V_"nom" I_"cc" = V_"nom"^2 \/ X$. Both approaches thus give the same expression:

$ gamma = V_"nom"^2 / (X dot S_"base") = S_"cc" / S_"base" $ <eq:gamma_icc>

The numerical difference comes only from the $X$ used: approach 1 approximates it by the reactance of a single typical line, whereas $I_"cc"$ embeds the true Thévenin impedance of the whole network seen from the bus. Approach 2 is therefore exact by construction, and $I_"cc"$ can be computed quickly by Powsybl before the load flow, bus by bus if a local $gamma$ is wanted.

#figure(
  table(
    columns: (auto, auto, auto, auto, auto),
    inset: 8pt,
    align: (left, right, right, right, right),
    table.header(
      [*Voltage level*], [*$I_"cc"$ (kA)*], [*$S_"cc"$ (MVA)*], [*$gamma$*], [*$omega_V = eta gamma$*],
    ),
    [420 kV], [63], [45 830], [458.3], [45.8],
    [245 kV], [50], [21 218], [212.2], [21.2],
    [145 kV], [40], [10 046], [100.5], [10.0],
    [63 kV],  [31.5], [3 437], [34.4], [3.4],
  ),
  caption: [Orders of magnitude of $gamma$ per voltage level ($S_"base" = 100$ MVA, $eta = 0.1$).],
) <tab:gamma_values>

Finally, since we would rather move a voltage setpoint --- often wrong, and always adjustable --- than inject reactive power on units that are already at their limits, we apply a de-prioritization factor $eta = 0.1$:

$ omega_V = eta dot gamma dot omega_Q = eta dot gamma approx 0.1 dot S_"cc" / S_"base" $ <eq:omega_v>

*Interpretation.* $gamma$ measures the voltage stiffness of the network. A strongly meshed network (large $S_"cc"$, small $X$) has a large $gamma$: there, one p.u. of voltage deviation corresponds to a lot of reactive power, so relaxing a voltage target is expensive. A radial network has a small $gamma$. The factor $eta$ tilts the arbitration towards relaxing $V$ targets rather than reactive balance.

== Summary

#figure(
  table(
    columns: (auto, auto, auto, auto),
    inset: 8pt,
    align: (left, left, left, left),
    table.header([*Weight*], [*Formula*], [*Depends on*], [*Physical meaning*]),
    [$omega_Q$], [$1$], [anchor (convention)], [cost per MVAr of deviation],
    [$omega_P$], [$rho_(P Q)$], [$Delta_P$, $P$ (DC pre-computation)], [MW/MVAr equivalence],
    [$omega_V$], [$eta gamma = eta S_"cc" \/ S_"base"$], [network ($I_"cc"$, $V_"nom"$), $eta$], [kV/MVAr equivalence],
  ),
  caption: [The three weights of the $ell_1$ model and their determinants.],
) <tab:weights_summary>

The inputs of the system are:

- *Engineering choices*: $eta$ (voltage de-prioritization), and the bounds $rho_min$, $rho_max$ of @eq:rho.
- *Network quantities*: $V_"nom"$, $S_"base"$, $S_"cc"$ (or $I_"cc"$) --- read or computed automatically.
- *Imbalance signal*: $Delta_P$, $P$ --- computed before solving under DC assumptions, determining $rho_(P Q)$.

Note that the $ell_2$-related parameters of the previous formulation ($tau_P$, $tau_Q$, $tau_V$, $lambda$, $mu$, the $ell_1\/ell_2$ crossover thresholds $Delta P_"seuil"$, $Delta Q_"seuil"$, $Delta V_"seuil"$, and the outer weights $w_K$) all disappear with the pure $ell_1$ choice. Six degrees of freedom are reduced to two effective ones.

== Indicative numerical values

With $S_"base" = 100$ MVA, $V_"nom" = 145$ kV, $I_"cc" = 40$ kA (hence $S_"cc" = 10 space 046$ MVA and $gamma = 100.5$), $eta = 0.1$, a total generation $P = 1000$ MW and a residual imbalance $abs(Delta_P) = 1$ MW, giving $rho_(P Q) = 1000 \/ 10 = 100$:

#figure(
  table(
    columns: (auto, auto, auto),
    inset: 8pt,
    align: (left, right, left),
    table.header([*Weight*], [*Value*], [*Reading*]),
    [$omega_Q$], [$1$], [1 MVAr of reactive deviation = 1 unit],
    [$omega_P$], [$100$], [1 MW of active deviation = 100 MVAr],
    [$omega_V$], [$10.0$], [1 p.u. of voltage deviation = 10 p.u. of reactive],
  ),
  caption: [Indicative weights on a 145 kV case.],
) <tab:numerical_values>

The ratio $rho_(P Q) = 100$ expresses a strong priority on preserving the active balance when the P balance is nearly closed. The factor $eta = 0.1$ encourages the solver to adjust voltage setpoints rather than to correct in reactive power. Reading the last line concretely: relaxing a voltage target by $0.01$ p.u. costs $0.1$ objective units, i.e. the equivalent of 10 MVAr --- a deliberate design choice, consistent with the fact that voltage setpoints in real datasets are the least reliable input.

= Implementation and testing framework <sec:implementation>

We implemented the resilient load flow model in Java, as part of the `powsybl-open-loadflow-knitro-solver` project#footnote[https://github.com/powsybl/powsybl-open-loadflow-knitro-solver]. This implementation is integrated into the PowSyBl#footnote[https://www.powsybl.org/] framework, an open-source project dedicated to grid analysis, visualization and simulation, co-developed with RTE (Réseau de Transport d'Électricité), the French TSO.

The codebase provides a complete Knitro-based AC load flow solver that formulates the problem as a nonlinear optimization model with slack variables and a penalized objective. The solver is fully compatible with IIDM (iTesla Internal Data Model) networks and can be used as a drop-in replacement for Newton-Raphson in most simulation contexts.

To ensure reliability and stability, a suite of non-regression tests is in place:

- basic convergence tests on standard IEEE networks;
- comparison of load flow results between Newton-Raphson and Knitro on nominal cases;
- verification that the solver preserves the expected behaviour.

These tests run automatically and serve as a foundation for extending validation to a wider range of operating scenarios and network configurations.

*Python interface.* A custom Python interface to the solver is available in the `pypowsybl-open-loadflow-knitro-solver` repository#footnote[https://github.com/Artelys/pypowsybl-open-loadflow-knitro-solver], which also provides a build example and a usage notebook. It exposes the resilient load flow on top of PyPowSyBl, which is convenient for prototyping, for post-processing the slacks and for reproducing the experiments described below.

*Benchmark repository.* The internal benchmark used for the experimental protocol of @sec:protocol is hosted in a dedicated repository#footnote[https://gitlab.artelys.lan/mdeboute/powsybl-open-loadflow-knitro-solver-benchmark --- internal access only.]. It can be run locally, or launched through the GitLab CI on an internal runner. The test datasets being confidential, they are stored on Artifactory and retrieved at run time rather than versioned with the code.

= Validation methodology <sec:validation>

== Comparison with Newton-Raphson on healthy networks

To assess the quality of the solution, we systematically compare the output of the resilient solver against a traditional Newton-Raphson run on the same healthy network, i.e. when both solvers converge. The quantities of interest --- active and reactive injections, voltage magnitudes, current intensities and phase angles --- are expressed in per-unit on a 100 MVA base. Fixed absolute tolerances are defined per variable to decide whether the results are equivalent.

#figure(
  image("misc/electrical_quantities.png"),
  caption: [Electrical quantities and tolerances used for the comparison.],
)

As established in @sec:inert, on these cases the two formulations share the same solution set, so any discrepancy beyond tolerance signals an implementation or a conditioning issue, not a modelling one.

== Stress tests: targeted perturbations

To validate robustness, we designed stress tests on IEEE networks (IEEE 9 to 300) by introducing controlled perturbations that push the system outside the feasible region of the standard formulation. These modifications are not random: they reproduce well-known physical sensitivities and real-life data defects. In each case we check both that a solution is returned and that *the active slacks point at the injected defect*.

=== Voltage regulation conflict

Real transmission datasets may contain inconsistent voltage controls, especially with remote voltage regulation. Two electrically close buses may carry different voltage targets, generating huge reactive flows that cannot be routed from distant generators through the network.

To emulate this, we introduce a localized perturbation creating a strong voltage conflict. We select a voltage-regulating generator, then a neighboring bus connected through a line with no voltage regulation, then a third bus neighboring the second one. If this third bus already hosts a generator, we modify its voltage target so that it slightly differs from the first one; otherwise we add a generator on the neighboring bus, regulating voltage at a different target. We then activate a remote voltage control for this generator on the second bus.

The line connecting the first two buses is modified as follows:

- series resistance set to zero;
- both shunt admittances set to zero;
- series reactance set to a very small positive value ($X = 10^(-4)$)#footnote[Keeping a small but nonzero reactance avoids two issues: it prevents numerical singularities in the Jacobian, and it ensures that Powsybl does not automatically merge the two connected buses, which happens below $10^(-8)$ p.u. The line thus remains in the model while creating a near short-circuit condition.].

This creates an infeasible or ill-conditioned situation for Newton-Raphson without globally corrupting the rest of the network. We expect the resilient model to resolve the infeasibility through the voltage magnitude slack of one of the controlled buses.

=== Active power transmission

Pan-national security studies require merging national networks. This merging process can disrupt the global active balance, especially when the exchanged powers anticipated at the borders by the different TSOs are inconsistent. A network with a large imbalance between active generation and demand may be unsolvable, because it ends up requiring flows on lines that are not dimensioned for them.

Emulation: select a load and set its active power to 10% of the total network demand. Newton-Raphson should not converge; Knitro is expected to converge using the active balance slack of the bus hosting the load, allowing the end user to identify the origin of the issue. Note that this case is precisely the one where $rho_(P Q)$ of @eq:rho is low, since $abs(Delta_P)$ is large: the model is expected to accept the active slack rather than to distort the voltage plan.

=== Reactive power transmission

Errors on shunt sections are frequent on real data and can significantly impair Newton-Raphson convergence. An erroneous shunt section position may let a bus produce a large amount of reactive power without any capability to export it towards the part of the network where it is needed.

Emulation: identify a bus where both a shunt and a generator are connected, make the generator regulate voltage locally, then modify the shunt section susceptance so that the shunt injects 1 GVAr (using the generator target voltage as reference). The problem becomes infeasible and Newton-Raphson should not converge. With Knitro, we expect a feasible solution obtained through the voltage magnitude slack of that bus, leading to the identification of the defect.

== Knitro stopping criteria

#figure(
  image("misc/knitro_stopping_criteria.png"),
  caption: [Knitro stopping criteria.],
)

== Results

Newton-Raphson typically fails to converge on these instances, because of the conflict between incompatible voltage setpoints and the strong electrical coupling between the generators.

The resilient formulation consistently converges thanks to its slack variables on voltage magnitude, which allow conflicting voltage targets to be relaxed selectively. This demonstrates the ability of an optimization-based formulation to handle infeasibilities locally and to restore feasibility through minimal, explainable relaxations.

= Experimental protocol <sec:protocol>

The following protocol isolates the effect of the two modelling decisions --- dropping the $ell_2$ term, then calibrating the weights.

+ *Benchmark*: the internal benchmark repository introduced in @sec:implementation serves as the common test bed, locally or through the CI.
+ *Baseline*: historical weights, $h(epsilon) = epsilon^2 + 3 abs(epsilon)$, $omega_P = omega_Q = omega_V = 1$.
+ *Pure $ell_1$, unit weights*: $h(s^+, s^-) = s^+ + s^-$, all weights at 1. Trivial to implement, isolates the sparsity effect of removing the quadratic term.
+ *Pure $ell_1$, calibrated weights*: @tab:weights_summary with the indicative values of @tab:numerical_values.
+ *Comparison metrics*, on every instance: number of non-zero slacks, concentration of the violation (share carried by the largest slack), objective value, physical consistency of the returned point, agreement between the localization of the slacks and the injected defect, iteration count and solve time.
+ *Sensitivity*: vary $eta$ and the parameters of $rho_(P Q)$ to map the arbitration between the three constraint families.
+ *If needed*: revisit the engineering parameters, or the form of $h$.
