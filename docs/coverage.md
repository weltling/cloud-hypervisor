# Code coverage

LLVM provides a set of tools to collect code coverage data and present the data
in human-consumable forms.

## CI unit test reports

The GNU `unit-tests-x86-64` job uploads `coverage.info` as
`unit-test-coverage-x86-64-gnu` on pushes to `main` and on other CI runs that
include unit tests. Only GNU runs on pushes to `main`. Other runs still test
musl without collecting coverage. Local coverage supports both GNU and musl.

For pull requests, the Actions run summary shows coverage for changed lines
that appear in the LCOV report. It compares the tested merge commit with its
base parent and does not enforce a minimum.

## Building a suitable binary

An instrumented binary can be built with the following command:

```shell
cargo clean && RUSTFLAGS='-C instrument-coverage' cargo build
```

Using either `debug` or `release` profile is fine. You will need to adjust
the path for some commands.

## Running the binary

Run the binary as you normally would. When the process exits, you will see
files with the prefix `profraw`.

Multiple runs of the same binary will produce multiple `profraw` files.

The more diverse the runs are, the better. Try to exercise different features
as much as possible.

## Combining raw data

Raw data files can be combined with `llvm-profdata`.

```shell
rustup component add llvm-tools-preview
# Assuming profraw files reside in the current directory and its children directories
find . -name '*.profraw' \
    -exec llvm-profdata merge -sparse -o coverage.profdata {} +
```

A file named `coverage.profdata` will be generated.

## Generating HTML files for human consumption

This can be done either with LLVM or `grcov`.

To install `grcov` and the Rust LLVM tools locally on Linux:

```shell
bash scripts/install_grcov.sh "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$PATH"
```

Here is an example using grcov.

```shell
# Assuming the profdata file is in the top level directory of the Cloud Hypervisor repository
grcov . --binary-path ./target/x86_64-unknown-linux-gnu/release -s . -t html --branch --ignore-not-existing -o coverage-html-output/
```

You can then open the `index.html` file under coverage-html-output to see the
results.

## Notes on running the in-tree integration tests and unit tests

To run unit tests without coverage:

```shell
scripts/dev_cli.sh tests --unit --libc gnu
```

To collect coverage, set `RUSTFLAGS` and `LLVM_PROFILE_FILE` before running
the tests. `dev_cli.sh` passes these settings to the test container.

Since the `profraw` files are generated from within the container, the file
paths embedded in the data files are going to be different. It is easier to do
the data processing from within the container if you don't want to fight the
tool chain.

```shell
# Set env to enable code coverage
export RUSTFLAGS="-Cinstrument-coverage"
export LLVM_PROFILE_FILE="ch-%p-%m.profraw"

# Run unit tests
scripts/dev_cli.sh tests --unit --libc gnu

# Run integration tests
scripts/dev_cli.sh tests --integration --libc gnu

# Export code coverage report
scripts/dev_cli.sh tests --coverage --libc gnu -- -- lcov
```
