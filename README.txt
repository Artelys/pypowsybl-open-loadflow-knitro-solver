# Requirement

- Knitro must be installed on your computer
- Environment variable KNITRODIR must be defined
- You must have a Knitro licence up to date

# Installation

PyPowSyBl with Knitro is released on Linux and Windows, to install :
pip install <filename>.whl

# Basic example
	import pypowsybl as pp
	import pypowsybl.loadflow as lf

    n = pp.network.create_ieee14()
    p = lf.Parameters(provider_parameters={'acSolverType': 'KNITRO', 'maxIterations' : '10'})
    results = lf.run_ac(n, p)

# Build from 
## Requirement

- Maven >= 3.1
- Cmake >= 3.20
- C++11 compiler
- Python >= 3.10 for Linux, Windows and MacOS (amd64 and arm64)
- Oracle GraalVM Java 21

## Versions

## Install from sources

export JAVA_HOME=<path_to_graalvm>
export KNITRODIR=<path_to_knitro>
export ARTELYS_LICENCE=<path_to_knitro_licence>

if needeed 

$env:GRAALVM_OPTIONS="-Dnative.encoding=UTF-8"
$env:CMAKE_PREFIX_PATH="D:\dev\knitro-solver-python\.knitro-solver-python\Lib\site-packages\pybind11\share\cmake\pybind11"
code "$HOME\.itools\config.yml"

cd <path_to_open-load-flow-knitro>
git checkout 
mvn clean install

cd <path_to_open-load-flow>
git checkout olf-2.1.1-not-vectorized
mvn clean install

cd <path_to_pypowsybl>
git checkout add-open-load-flow-knitro-v3.14
pip install .

with uv : Build/install your package	uv pip install .


### Known issues on Linux:

Make sure java has the right version : java --version
Make sure mvn use the right java version : mvn --version

Error on build : "Could NOT find Python (missing Python_INCLUDE_DIRS Development.Module)"
Fix : install python3-dev
