#!/bin/bash
# Start OSA with BEAM scheduler busy-wait disabled
# Without +sbwt none, BEAM schedulers spin at ~85% per core even when idle
export ERL_FLAGS="+sbwt none +sbwtdcpu none +sbwtdio none"
cd "$(dirname "$0")"
exec mix run -e "OptimalSystemAgent.CLI.serve()"
