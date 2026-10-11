#!/bin/zsh
set -eu
collector_dir=${0:A:h}
/usr/bin/perl "$collector_dir/collect_browser_diagnostics.pl" "$@"
print 'Attach the JSON report at the path shown above to the conversation.'
