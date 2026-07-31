# pypowsybl-open-loadflow-knitro-solver

## PowSyBl vs PowSyBl Open Load Flow Knitro Solver

PowSyBl Open Load Flow Knitro Solver is an extension to [PowSyBl Open Load Flow](https://github.com/powsybl/powsybl-open-loadflow) allowing to solve
the load flow equations with the **non-linear solver Knitro** instead of the default **Newton-Raphson** method.

The Knitro solver extension offers two different ways to model the load flow problem: either as a **constraint satisfaction problem** (without an objective function) or as an **optimisation problem** with relaxed constraints (and an objective function minimizing the violations). 

To better understand the objective function, variable weights implementation of the **RELAXED** solver, refer to the internal documentation available at: [documentation Knitro Relaxed Solver](https://typst.app/project/pbarctkphiuUcXw9qVjZJs)

## PyPowSyBl with Knitro Solver extension: 

The goal of this repositery and extension is to have a python vizualization, to interpret the results. 

## Getting Started 

The value of those parameters can be provided though the provider_parameters attribute of the load flow parameters object : 

```python
import pypowsybl as pp
import pypowsybl.loadflow as lf

n = pp.network.create_ieee14()
p = lf.Parameters(provider_parameters={'acSolverType': 'KNITRO', 'solverType': 'RELAXED', 'maxKnitroIterations': '10', 'exportSolution': Path_to_CSV })
results = lf.run_ac(n, p)
```

Open load flow knitro solver provide a set of specific parameters :

```python
 [ 'acSolverType': 'KNITRO', 'solverType':'RELAXED', 'losses': DC_LOSSES, 
  'maxKnitroIterations': '200', 'gradientComputationMode': '1', 'threadNumber':'1', 
  'gradientUserRoutine': '2', 'hessianComputationMode': '6', 'minRealisticVoltage': '0.5', 
  'maxRealisticVoltage': '1.5', 'slackThreshold':'0.000001', 
  'relativeFeasibilityStoppingCriteria': '0.000001', 'absoluteFeasibilityStoppingCriteria':'0.001',
  'relativeOptimalityStoppingCriteria': '0.000001', 'absoluteOptimalityStoppingCriteria': ' 0.001', 'optimalityStoppingCriteria':'0.0000001', 
  'alwaysUpdateNetwork': 'false','exportSolution': Path_to_CSV ]
 ```

1. **Knitro Solver Type**:
    - Specifies the way to model the load flow problem : 
    - **Knitro Solver Types**:
      - `STANDARD (default)` : the constraint satisfaction problem formulation and a direct substitute to the Newton-Raphson solver.
      - `RELAXED` : the optimisation problem formulation relaxing satisfaction problem.
      - `USE_REACTIVE_LIMITS` : the optimization problem formulation relaxing satisfaction problem and integrating reactive limits in constraints.
      Note that using this solver requires disabling the `useReactiveLimits` parameter in `LoadFlowParameters`, for compatibility reasons with the way outer 
      loops are launched in Open-Load-Flow. Doing so, the Open-Load-Flow checks that disable voltage control when the reactive power bounds are not sufficiently 
      large (see [OLF documentation](https://powsybl.readthedocs.io/projects/powsybl-open-loadflow/en/latest/loadflow/parameters.html)) are not performed, which may explain some of the differences in results between the Newton–Raphson solver and the Knitro solver. 
      This will be addressed in a near future.
    - Use `setKnitroSolverType` in the `KnitroLoadFlowParameters` extension.

2. **DC Losses approximation**:
    - Default value: 10 MW
    - Can be set manually or computed by running a DC Load Flow on the network.
    - Use `losses`
```python 
python 
lf.run_dc(network_DC)
voltage_level_df = network_DC.get_voltage_levels()
losses = calculate_dc_losses(network_DC, voltage_level_df)
 ```

3. **Export Solution**
    - Default value: export disabled 
    - When enabled, a CSV file is exported containing information for each slack (type, value, location...).
    - Use `exportSolution`.
    -  The exported CSV file can subsequently be used for visualization with the `nad_explorer_with_slack` function through the `slack_info` parameter.

4. **LOGGING MODE**
- INFO : only the 5th lagest slack (in p.u value) per type are readable in the logging messages
- DEBUG : all the slack are readable 

Please see open load flow knitro solver readme https://github.com/powsybl/powsybl-open-loadflow-knitro-solver#knitro-parameters for details on each parameter.

### Requirement

- Knitro must be installed on your computer
- Environment variable KNITRODIR must be defined
- You must have a Knitro licence up to date

### Installation

PyPowSyBl with Knitro is released on Linux and Windows, to install :
pip install <filename>.whl

### Build from 
#### Requirement

- Maven >= 3.1
- Cmake >= 3.20
- C++11 compiler
- Python >= 3.10 for Linux, Windows and MacOS (amd64 and arm64)
- Oracle GraalVM Java 21

#### Versions
#### Generate config files with GraalVM

To generate the config file, we need to execute a graalVM command line that run a java main class and create .json config files with any detected dependencies which are used by this class.

##### Add main and build a .jar

Create and add a java main class to the manifest.
This main class should call functions using missing dependencies in pypowsybl.

Then build the jar using command: 
mvn clean install

Move to where the jar is:
cd [path_to_PyPowsyb]\java\pypowsybl\target

Run the following command using  GraalVM java
java -agentlib:native-image-agent=config-output-dir=config-dir -jar .\pypowsybl-java.jar

tips: to run java from GraalVM you can use this input instead of 'java':
& [path_to_graalvm]\bin\java.exe' 
& "$env:JAVA_HOME\bin\java.exe" -agentlib:native-image-agent=config-output-dir=config-dir -jar .\pypowsybl-java.jar
Sous wsl:
wsl

##### Extend existing config files

Use the config-merge-dir option to extend existing configuration files rather than overwriting them, which is useful for covering multiple execution paths.

Follow previous instructions, and add the following option to the java command:
-agentlib:native-image-agent=config-merge-dir=/path/to/config-dir

Whole command where the .jar was generated would be:
java -agentlib:native-image-agent=config-merge-dir=[PATH_TO_POWSYBL]\java\pypowsybl\src\main\resources\META-INF\native-image -jar .\pypowsybl-java.jar

#### Install from sources

export JAVA_HOME=<path_to_graalvm>
export KNITRODIR=<path_to_knitro>
export ARTELYS_LICENCE=<path_to_knitro_licence>

if needeed 

$env:GRAALVM_OPTIONS="-Dnative.encoding=UTF-8"
$env:CMAKE_PREFIX_PATH=<path_to_cmake>

cd <path_to_open-load-flow-knitro> 
git checkout benchmark-parametrized-test (30.07.2026 soon to be main branch)
mvn clean install

(idealy this step will not be needed once the bump of version:2.1.1 with the vectorization)
cd <path_to_open-load-flow> 
git checkout olf-2.1.1-not-vectorized
mvn clean install

cd <path_to_pypowsybl>
git checkout add-open-load-flow-knitro-v3.14
pip install .

#### Known issues on Linux:

Make sure java has the right version : java --version
Make sure mvn use the right java version : mvn --version

Error on build : "Could NOT find Python (missing Python_INCLUDE_DIRS Development.Module)"
Fix : install python3-dev