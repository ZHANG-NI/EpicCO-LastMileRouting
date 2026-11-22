# AlphaCO: Last-Mile Routing

The solver that [AlphaCO](https://github.com/ZHANG-NI/AlphaCO) produced for the Amazon Last Mile Routing Research Challenge, starting from the first-ranked approach of the challenge (W. Cook, S. Held, and K. Helsgaun, Transportation Science, 2024; https://github.com/heldstephan/jpt-amz).

## Run

```
mkdir -p bin
bash build.sh bin
bin/solver <instance> <solution> -t <seconds> -seed <seed>
```

`build.sh` and the solver need the challenge's data (set `LMR_DATA` and `LMR_HIST`; see the first lines of `build.sh`).
