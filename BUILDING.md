# Building the custom PyPowSyBl wheel

The Knitro solver is a Java extension of Open Load Flow, compiled into the PyPowSyBl native image.
Using it from Python therefore requires rebuilding PyPowSyBl with that extension on the classpath.

## Prerequisites

| Tool | Version |
|------|---------|
| Oracle GraalVM for Java | 21 |
| Maven | ≥ 3.1 |
| CMake | ≥ 3.20 |
| C++ compiler | C++11 |
| Python | ≥ 3.10 |
| Artelys Knitro | 15.1.0 |

```bash
export JAVA_HOME=<path_to_graalvm>
export KNITRODIR=<path_to_knitro>
export ARTELYS_LICENSE=<path_to_knitro_license>
```

Check that Maven picks up GraalVM and not another JDK:

```bash
java --version   # must report GraalVM 21
mvn --version    # must report the same Java version
```

### Knitro Java bindings

The Knitro Java bindings ship as a private JAR that is not on Maven Central and must be installed
into the local Maven repository first:

```bash
# Linux / macOS
mvn install:install-file -Dfile="$KNITRODIR/examples/Java/lib/Knitro-Interfaces-2.5-KN_15.1.0.jar" \
  -DgroupId=com.artelys -DartifactId=knitro-interfaces -Dversion=15.1.0 -Dpackaging=jar -DgeneratePom=true
```

```powershell
# Windows (PowerShell)
mvn install:install-file -Dfile="$env:KNITRODIR/examples/Java/lib/Knitro-Interfaces-2.5-KN_15.1.0.jar" `
  -DgroupId="com.artelys" -DartifactId=knitro-interfaces -Dversion="15.1.0" -Dpackaging=jar -DgeneratePom=true
```

## Build steps

The three repositories must be built in this order, each installing its artifacts into the local
Maven repository for the next one.

### 1. Open Load Flow

The Knitro solver currently depends on the **non-vectorized** 2.1.1 version of Open Load Flow, which
lives on a dedicated branch:

```bash
git clone https://github.com/powsybl/powsybl-open-loadflow.git
cd powsybl-open-loadflow
git checkout olf-2.1.1-not-vectorized
mvn clean install -DskipTests
```

### 2. Open Load Flow Knitro solver

```bash
git clone https://github.com/powsybl/powsybl-open-loadflow-knitro-solver.git
cd powsybl-open-loadflow-knitro-solver
mvn clean install -DskipTests
```

The CSV slack export (`exportSolution`) and the `losses` parameter used by this demo require
[PR #28](https://github.com/powsybl/powsybl-open-loadflow-knitro-solver/pull/28) or later.

### 3. PyPowSyBl

```bash
git clone https://github.com/powsybl/pypowsybl.git
cd pypowsybl
git checkout add-open-load-flow-knitro-v3.14
pip install .
```

To produce a distributable wheel instead of an in-place install:

```bash
pip install build
python -m build --wheel
```

## Regenerating the GraalVM reflection configuration

PyPowSyBl is compiled to a native image, so every class reached through reflection must be declared
in `META-INF/native-image`. When the Java side gains a dependency that the current configuration
does not cover, the configuration files have to be regenerated with the GraalVM tracing agent.

1. Add a Java `main` class to `java/pypowsybl` that exercises the new code paths, and declare it in
   the JAR manifest.
2. Build the JAR:
   ```bash
   mvn clean install
   ```
3. Run it under the tracing agent, from the directory containing the JAR:
   ```bash
   cd <path_to_pypowsybl>/java/pypowsybl/target
   "$JAVA_HOME/bin/java" -agentlib:native-image-agent=config-output-dir=config-dir -jar pypowsybl-java.jar
   ```
   This writes the detected reflection, JNI and resource declarations into `config-dir/`.
4. To *extend* the existing configuration rather than overwrite it — which is what you want when
   covering several execution paths — use `config-merge-dir` pointing at the checked-in files:
   ```bash
   "$JAVA_HOME/bin/java" \
     -agentlib:native-image-agent=config-merge-dir=<path_to_pypowsybl>/java/pypowsybl/src/main/resources/META-INF/native-image \
     -jar pypowsybl-java.jar
   ```

## Known issues

**`Could NOT find Python (missing Python_INCLUDE_DIRS Development.Module)`** (Linux)
Install the Python development headers: `sudo apt install python3-dev`.

**Encoding errors during the native image build** (Windows)
```powershell
$env:GRAALVM_OPTIONS = "-Dnative.encoding=UTF-8"
```

**CMake cannot be found**
```powershell
$env:CMAKE_PREFIX_PATH = "<path_to_cmake>"
```
