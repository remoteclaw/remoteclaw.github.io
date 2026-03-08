# RemoteClaw "next" channel installer — latest build from main branch.
# Usage: irm https://next.remoteclaw.ps | iex
#
# This wrapper runs the standard installer with the "next" dist-tag,
# which tracks every commit on main. Newest features, updated continuously.

$ErrorActionPreference = "Stop"
$script = Invoke-RestMethod https://remoteclaw.org/install.ps1
$sb = [scriptblock]::Create($script)
& $sb -Tag "next"
