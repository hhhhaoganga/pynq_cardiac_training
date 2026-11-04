#!/bin/bash
# Server side: full v2 gate chain. csim (150 cases, bit-exact vs frozen
# expected.bin) -> csynth -> cosim (cases 13/73/130, Verilog/xsim) -> export
# IP (shape_top 2.0) and unpack it into src/ip_repo_shape_v2. Stops at the
# first failing stage.
here=$(cd "$(dirname "$0")" && pwd)
ws=$(dirname "$(dirname "$here")")
logs=$ws/logs
for stage in csim csynth cosim export; do
    "$here/run_stage.sh" "$stage"
    rc=$?
    echo "STAGE $stage exit=$rc"
    case $stage in
        csim)  n=$(grep -c '^PASS case=' "$logs/hls_csim.log"); echo "csim pass_cases=$n"
               grep -q 'PASS top cases=150' "$logs/hls_csim.log" || { grep -E 'FAIL|ERROR' "$logs/hls_csim.log" | head; exit 1; } ;;
        cosim) grep -E 'PASS case=|PASS top|FAIL|ERROR' "$logs/hls_cosim.log" | head -10
               rpt=$ws/work/hls_shape_v2/solution1/sim/report/shape_top_cosim.rpt
               [ -f "$rpt" ] && grep -E 'Verilog|Pass|Fail' "$rpt" | head -5
               grep -q 'PASS top cases=3' "$logs/hls_cosim.log" || exit 1 ;;
        *)     [ $rc -eq 0 ] || { tail -n 20 "$logs/hls_$stage.log"; exit 1; } ;;
    esac
done
zip=$ws/src/shape_top_v2_ip.zip
repo=$ws/src/ip_repo_shape_v2/shape_top
mkdir -p "$repo"
(cd "$repo" && unzip -oq "$zip")
echo "IP_EXPORTED $(sha256sum "$zip" | cut -c1-64)"
grep -oE '<spirit:version>[^<]+' "$repo/component.xml" | head -1
echo VERIFY_EXPORT_DONE
