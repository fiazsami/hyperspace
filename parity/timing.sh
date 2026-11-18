# Sourced, not run: the one definition of how a pass is timed, shared by
# refcheck.sh (this Mac, two commits) and basemac.sh (another Mac, one commit),
# whose numbers are divided by each other and so must time the same workload.
#
# The saver's own look (look=saver), each pass's own frames, at 3440x1440: the
# resolution of the displays the measurements were taken on.
TIME_ARGS=(renderer=metal look=saver time shots=1 w=3440 h=1440)

# Whether the parity binary $1 has look=saver and time (ss-z8x.1 on). Its usage
# is captured, not piped: parity exits 2 on printing it, which pipefail would
# take for a failure.
times_as_saver(){
    local usage
    usage=$("$1" 2>&1)
    [[ $usage == *look=saver* ]]
}
