# PyPowSyBl — Open Load Flow Knitro solver

[![License: MPL 2.0](https://img.shields.io/badge/license-MPL_2.0-blue.svg)](https://www.mozilla.org/en-US/MPL/2.0/)

A **resilient AC load flow** for [PowSyBl](https://www.powsybl.org), usable from Python.

When a network is too degraded, the default **Newton-Raphson** solver diverges: it tells you *that*
there is no solution, but not *where* the problem is. The
[PowSyBl Open Load Flow Knitro solver](https://github.com/powsybl/powsybl-open-loadflow-knitro-solver)
restates the load flow as an optimisation problem solved by
[Artelys Knitro](https://www.artelys.com/solvers/knitro/), in which the power flow equations may be
violated at a cost. Each violation is carried by a **slack variable** that the objective function
minimises, so the solver always returns an answer — and the non-zero slacks pinpoint **where** the
network is infeasible and of **which nature** the infeasibility is:

| Slack | Meaning |
|-------|---------|
| 🔴 **P** | active power imbalance at a bus |
| 🔵 **Q** | reactive power imbalance at a bus |
| 🟢 **V** | voltage set point that cannot be held |

This repository packages that solver behind the **PyPowSyBl** Python API and ships an interactive
notebook that runs it and maps the slacks onto a network area diagram.

## Contents

| Path | Description |
|------|-------------|
| [`knitro_solver_demo.ipynb`](knitro_solver_demo.ipynb) | End-to-end demo: Newton-Raphson diverges, Knitro converges, slacks are visualised |
| [`slack_viz_utils.py`](slack_viz_utils.py) | Visualisation helpers (DC losses estimation, slack join, NAD explorer) |
| `data/` | The IEEE 14-bus network, perturbed so that Newton-Raphson diverges |
| `results/` | Reference CSV export, regenerated each time the notebook runs |
| [`BUILDING.md`](BUILDING.md) | How to build the custom PyPowSyBl wheel from source |
| `docs/` | Reference paper describing the relaxed optimisation model (PDF + Typst source) |

## Requirements

- **Artelys Knitro 15.1.0** installed, with a valid license
  ([trial version](https://www.artelys.com/solvers/knitro/programs/#trial))
- Environment variables `KNITRODIR` (Knitro installation directory) and `ARTELYS_LICENSE`
  (license file path, or its content)
- **Python ≥ 3.10** (Linux or Windows)

## Installation

The Knitro solver is not part of the official PyPowSyBl release: it requires a **custom wheel**,
which you build from source following [`BUILDING.md`](BUILDING.md).

Once you have the wheel:

```bash
pip install -r requirements.txt                                     # notebook dependencies
pip install --no-deps --force-reinstall pypowsybl-<version>-<platform>.whl   # the custom wheel
```

> **Order matters.** `pypowsybl-jupyter` depends on `pypowsybl`, so installing it *after* the custom
> wheel pulls the official PyPI build over it and silently removes the Knitro solver. Install the
> wheel last, with `--no-deps` so that pip does not re-resolve `pypowsybl` in the process, and
> `--force-reinstall` because pip would otherwise consider the already-installed official build to
> satisfy the requirement.
>
> Running the [demo notebook](knitro_solver_demo.ipynb) top to bottom is the check that the right
> build is active: the Knitro cell fails with `AC Solver 'KNITRO' not found` if it is not.

## Quick start

```python
import pypowsybl.loadflow as lf
import pypowsybl.network as pn

network = pn.load("data/ieee14-voltage-perturbation.xiidm")

parameters = lf.Parameters(
    distributed_slack=False,      # the solver handles the imbalance with its P slacks
    use_reactive_limits=False,    # see "Problem formulations" below
    provider_parameters={
        "acSolverType": "KNITRO",
        "solverType": "RELAXED",
        "losses": "10.0",                        # MW, weights the objective function
        "exportSolution": "results/my-run",      # writes my-run.csv and my-run_optim_info.csv
    },
)
lf.run_ac(network, parameters)
```

`exportSolution` writes two CSV files (`;`-separated):

- `<prefix>.csv` — one row per activated slack: bus, type (`P`/`Q`/`V`), value in p.u., and the
  network elements attached to that bus;
- `<prefix>_optim_info.csv` — solver summary: total penalty, penalty per slack type, status,
  iteration count.

Then run the [demo notebook](knitro_solver_demo.ipynb) to see how those slacks are turned into an
interactive diagram.

## Knitro solver parameters

All parameters below are passed as **strings** in the `provider_parameters` dictionary of
`lf.Parameters`. Every one of them is optional except `acSolverType`.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `acSolverType` | `NEWTON_RAPHSON` | Set to `KNITRO` to use this solver |
| `solverType` | `STANDARD` | Problem formulation — see below |
| `losses` | `10.0` | Estimated network active losses in MW, used to weight the objective function |
| `exportSolution` | *(empty — disabled)* | Path prefix of the CSV export of the slacks |
| `maxKnitroIterations` | `200` | Maximum number of solver iterations |
| `threadNumber` | `-1` | Number of threads; `-1` lets Knitro decide. Must be `1` when `gradientComputationMode` is `2` or `3` |
| `gradientComputationMode` | `1` | `1` exact (gradients provided by PowSyBl), `2` forward finite differences, `3` central finite differences |
| `gradientUserRoutine` | `2` | Jacobian sparsity: `1` dense, `2` sparse (recommended) |
| `hessianComputationMode` | `6` | Hessian approximation; `6` is L-BFGS, recommended for large networks |
| `lowerVoltageBound` | `0.5` | Lower bound on voltage magnitude, in p.u. |
| `upperVoltageBound` | `1.5` | Upper bound on voltage magnitude, in p.u. |
| `slackThreshold` | `1e-6` | Below this value (p.u.) a slack is considered inactive and not reported |
| `relativeFeasibilityStoppingCriteria` | `1e-6` | Relative feasibility tolerance |
| `absoluteFeasibilityStoppingCriteria` | `1e-3` | Absolute feasibility tolerance |
| `relativeOptimalityStoppingCriteria` | `1e-6` | Relative KKT (optimality) tolerance |
| `absoluteOptimalityStoppingCriteria` | `1e-3` | Absolute KKT (optimality) tolerance |

See the [upstream parameter reference](https://github.com/powsybl/powsybl-open-loadflow-knitro-solver#knitro-parameters)
for the full description of each one.

### Problem formulations (`solverType`)

| Value | Formulation |
|-------|-------------|
| `STANDARD` *(default)* | Constraint satisfaction problem, a direct substitute for Newton-Raphson. No objective function, no slacks. |
| `RELAXED` | Optimisation problem: the power flow equations are relaxed with P/Q/V slacks and the objective minimises the violations. **This is the resilient mode** demonstrated here. |
| `USE_REACTIVE_LIMITS` | Same as `RELAXED`, with the generator reactive limits integrated as constraints of the model. |

`USE_REACTIVE_LIMITS` **requires** `use_reactive_limits=False` in `LoadFlowParameters` — the solver
rejects the run otherwise, since the reactive limits are already part of its model and the Open Load
Flow reactive limits outer loop would fight it. As a side effect, the Open Load Flow checks that
disable voltage control when the reactive power bounds are too narrow are skipped, which explains
part of the differences observed between Newton-Raphson and Knitro results.

`RELAXED` accepts both values. The demo notebook also sets `use_reactive_limits=False` with
`RELAXED`, so that the slacks reflect the raw infeasibility of the network rather than the result of
an outer loop having already moved the generators.

### Logging

The solver reports the activated slacks through the `powsybl` logger:

```python
import logging
logging.basicConfig()
logging.getLogger("powsybl").setLevel(logging.INFO)   # 5 largest slacks per type
logging.getLogger("powsybl").setLevel(logging.DEBUG)  # all slacks
```

## Documentation

[**Artelys Knitro in PowSyBl Open Load Flow: a Resilient Optimization-Based AC Load Flow**](docs/knitro-olf-documentation.pdf)
— Lavine, Makhen, Archambault, Arvy, Debouté, Godard (Artelys) — describes the model in full: the
bounded-sign slack variables on the P, Q and V equations, the pure ℓ1 penalty that keeps the
returned solution diagnosable, and the methodology used to derive the three weights
(ω<sub>P</sub>, ω<sub>Q</sub>, ω<sub>V</sub>) from physical quantities.

The Typst source is in [`docs/main.typ`](docs/main.typ), its figures in `docs/misc/`.

## License

This project is licensed under the [Mozilla Public License 2.0](LICENSE), like the rest of the
PowSyBl ecosystem.
