<#
.SYNOPSIS
  Drains under-used nodes from the Materialize node pool of an AKS cluster so the cluster autoscaler can remove them.

.DESCRIPTION
  1. Fetches credentials into a temporary kubeconfig (your own kubeconfig is not touched).
  2. Finds the Materialize node pool (the pool hosting environmentd, or -NodePool).
  3. Simulates moving each node's pods onto the remaining nodes using CPU/memory/pod-count requests,
     staying under -MaxUtilizationPercent of allocatable.
  4. Drains the nodes that fit (lightest first, nodes hosting environmentd/balancerd/console last).
     After each drain it checks that no new pods are Pending; otherwise it uncordons and stops.

  The autoscaler deletes the empty nodes after roughly 10-15 minutes.
  The simulation ignores node selectors, affinity and PVC zone constraints, and checks requests, not live usage.

.PARAMETER ClusterName
  AKS cluster name.

.PARAMETER ResourceGroup
  Resource group of the AKS cluster.

.PARAMETER SubscriptionId
  Optional subscription to select before fetching credentials.

.PARAMETER NodePool
  Optional agentpool label to consolidate. Auto-detected from the environmentd pod when omitted.

.PARAMETER Namespace
  Namespace holding the Materialize pods. Default: materialize-environment.

.PARAMETER MinNodes
  Never go below this many schedulable nodes in the pool. Default: 1.

.PARAMETER MaxUtilizationPercent
  Max requested CPU/memory/pods as a percentage of allocatable on the remaining nodes. Default: 90.

.PARAMETER DrainTimeoutSeconds
  Timeout passed to kubectl drain. Default: 300.

.PARAMETER SettleSeconds
  How long to wait after each drain for new Pending pods to schedule. Default: 120.

.EXAMPLE
  .\Consolidate-MaterializeNodes.ps1 -ClusterName sgsse7-3-au-materialize-aks -ResourceGroup SGSSE7-3-AU-MATERIALIZE-RESOURCES -WhatIf
  Shows the plan only.

.EXAMPLE
  .\Consolidate-MaterializeNodes.ps1 -ClusterName sgsse7-3-au-materialize-aks -ResourceGroup SGSSE7-3-AU-MATERIALIZE-RESOURCES
  .\Consolidate-MaterializeNodes.ps1 -ClusterName sgsse7-temp-materialize-aks -ResourceGroup SGSSE7-TEMP-MATERIALIZE-RESOURCES
  .\Consolidate-MaterializeNodes.ps1 -ClusterName sgsse7-2-au-materialize-aks -ResourceGroup SGSSE7-2-AU-MATERIALIZE-RESOURCES
  Plans, then asks for confirmation before each drain (use -Confirm:$false to skip the prompts).
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
  [Parameter(Mandatory = $true)][string]$ClusterName,
  [Parameter(Mandatory = $true)][string]$ResourceGroup,
  [string]$SubscriptionId,
  [string]$NodePool,
  [string]$Namespace = 'materialize-environment',
  [ValidateRange(1, 100)][int]$MinNodes = 1,
  [ValidateRange(10, 100)][int]$MaxUtilizationPercent = 90,
  [int]$DrainTimeoutSeconds = 300,
  [int]$SettleSeconds = 120
)

$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

function Invoke-Kubectl {
  # Returns stdout lines; throws on a non-zero exit code. stderr is discarded unless -ShowStderr.
  param([string[]]$KubectlArgs, [switch]$ShowStderr)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($ShowStderr) { $out = & kubectl @KubectlArgs 2>&1 | ForEach-Object { $_.ToString() } }
    else { $out = & kubectl @KubectlArgs 2>$null }
  } finally { $ErrorActionPreference = $prev }
  if ($LASTEXITCODE -ne 0) { throw "kubectl $($KubectlArgs -join ' ') failed (exit $LASTEXITCODE)`n$($out -join "`n")" }
  return $out
}

function ConvertTo-MilliCpu([string]$v) {
  if ([string]::IsNullOrWhiteSpace($v) -or $v -eq '<none>') { return 0.0 }
  if ($v.EndsWith('m')) { return [double]::Parse($v.TrimEnd('m'), $inv) }
  return [double]::Parse($v, $inv) * 1000
}

function ConvertTo-Bytes([string]$v) {
  if ([string]::IsNullOrWhiteSpace($v) -or $v -eq '<none>') { return 0.0 }
  if ($v -notmatch '^([0-9.]+)(Ki|Mi|Gi|Ti|k|K|M|G|T|m)?$') { return 0.0 }
  $n = [double]::Parse($Matches[1], $inv)
  switch ($Matches[2]) {
    'Ki' { $n * 1024 } 'Mi' { $n * 1MB } 'Gi' { $n * 1GB } 'Ti' { $n * 1TB }
    'k' { $n * 1e3 } 'K' { $n * 1e3 } 'M' { $n * 1e6 } 'G' { $n * 1e9 } 'T' { $n * 1e12 }
    'm' { $n / 1000 } default { $n }
  }
}

# Sums a comma-separated per-container list (e.g. "100m,<none>,2").
function Sum-List([string]$v, [scriptblock]$conv) {
  $t = 0.0
  foreach ($p in ($v -split ',')) { $t += (& $conv $p) }
  return $t
}

function Get-PendingPods {
  $lines = Invoke-Kubectl @('get', 'pods', '-A', '--field-selector=status.phase=Pending', '-o', 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name', '--no-headers')
  return @($lines | Where-Object { $_ -and $_ -notmatch '^No resources' } | ForEach-Object { ($_ -split '\s+')[0..1] -join '/' })
}

function Get-ClusterState {
  $nodes = @{}
  $nodeLines = Invoke-Kubectl @('get', 'nodes', '-o', 'custom-columns=NAME:.metadata.name,POOL:.metadata.labels.agentpool,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory,PODS:.status.allocatable.pods,UNSCHED:.spec.unschedulable', '--no-headers')
  foreach ($l in $nodeLines) {
    $f = $l.Trim() -split '\s+'
    if ($f.Count -lt 6) { continue }
    $nodes[$f[0]] = [pscustomobject]@{
      Name = $f[0]; Pool = $f[1]; Cpu = (ConvertTo-MilliCpu $f[2]); Mem = (ConvertTo-Bytes $f[3])
      MaxPods = [double]::Parse($f[4], $inv); Cordoned = ($f[5] -eq 'true')
    }
  }
  $pods = New-Object System.Collections.ArrayList
  $podLines = Invoke-Kubectl @('get', 'pods', '-A', '--field-selector=status.phase!=Succeeded,status.phase!=Failed', '-o', 'custom-columns=NS:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName,OWNER:.metadata.ownerReferences[0].kind,CPU:.spec.containers[*].resources.requests.cpu,MEM:.spec.containers[*].resources.requests.memory', '--no-headers')
  foreach ($l in $podLines) {
    $f = $l.Trim() -split '\s+'
    if ($f.Count -lt 6 -or $f[2] -eq '<none>') { continue }
    [void]$pods.Add([pscustomobject]@{
      Ns = $f[0]; Name = $f[1]; Node = $f[2]; Daemon = ($f[3] -eq 'DaemonSet')
      Cpu = (Sum-List $f[4] ${function:ConvertTo-MilliCpu}); Mem = (Sum-List $f[5] ${function:ConvertTo-Bytes})
    })
  }
  return [pscustomobject]@{ Nodes = $nodes; Pods = $pods }
}

function Format-Gi([double]$b) { '{0:N1}' -f ($b / 1GB) }

foreach ($tool in 'az', 'kubectl') {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "$tool not found on PATH." }
}

$prevKubeconfig = $env:KUBECONFIG
$kubeconfig = Join-Path $env:TEMP ("mz-consolidate-{0}.yaml" -f [guid]::NewGuid())

try {
  if ($SubscriptionId) { & az account set --subscription $SubscriptionId; if ($LASTEXITCODE -ne 0) { throw 'az account set failed.' } }
  & az aks get-credentials --resource-group $ResourceGroup --name $ClusterName --file $kubeconfig --overwrite-existing --only-show-errors
  if ($LASTEXITCODE -ne 0) { throw 'az aks get-credentials failed.' }
  $env:KUBECONFIG = $kubeconfig

  $state = Get-ClusterState
  $nodes = $state.Nodes

  if (-not $NodePool) {
    $envPod = $state.Pods | Where-Object { $_.Ns -eq $Namespace -and $_.Name -match '-environmentd-' } | Select-Object -First 1
    if (-not $envPod) { throw "No environmentd pod found in namespace '$Namespace'. Pass -NodePool explicitly." }
    $NodePool = $nodes[$envPod.Node].Pool
  }
  Write-Host "Cluster: $ClusterName  Node pool: $NodePool  Namespace: $Namespace" -ForegroundColor Cyan

  $poolNodes = @($nodes.Values | Where-Object { $_.Pool -eq $NodePool })
  $cordoned = @($poolNodes | Where-Object { $_.Cordoned })
  if ($cordoned) { Write-Host ("Already cordoned (waiting for autoscaler?): " + (($cordoned.Name) -join ', ')) -ForegroundColor Yellow }
  $remaining = @($poolNodes | Where-Object { -not $_.Cordoned })

  # Per-node load (all pods, daemonsets included) and the movable pods per node.
  $load = @{}; $movable = @{}; $critical = @{}
  foreach ($n in $remaining) { $load[$n.Name] = @{ Cpu = 0.0; Mem = 0.0; Pods = 0 }; $movable[$n.Name] = @(); $critical[$n.Name] = 0 }
  foreach ($p in $state.Pods) {
    if (-not $load.ContainsKey($p.Node)) { continue }
    $load[$p.Node].Cpu += $p.Cpu; $load[$p.Node].Mem += $p.Mem; $load[$p.Node].Pods += 1
    if (-not $p.Daemon) { $movable[$p.Node] += $p }
    if ($p.Ns -eq $Namespace -and $p.Name -match '-(environmentd|balancerd|console)-') { $critical[$p.Node] += 1 }
  }

  Write-Host "`nCurrent state ($($remaining.Count) schedulable nodes):"
  $remaining | ForEach-Object {
    '  {0,-40} cpu {1,6:N1}/{2,5:N1}   mem {3,6}/{4,5} GiB   pods {5}/{6}   critical {7}' -f $_.Name, ($load[$_.Name].Cpu / 1000), ($_.Cpu / 1000), (Format-Gi $load[$_.Name].Mem), (Format-Gi $_.Mem), $load[$_.Name].Pods, $_.MaxPods, $critical[$_.Name]
  }

  # Greedy plan: lightest node first, first-fit-decreasing of its movable pods onto the others.
  $util = $MaxUtilizationPercent / 100.0
  $plan = New-Object System.Collections.ArrayList
  while ($remaining.Count -gt $MinNodes) {
    $candidates = $remaining | Sort-Object @{ Expression = { $critical[$_.Name] } }, @{ Expression = { $load[$_.Name].Mem } }
    $placed = $false
    foreach ($cand in $candidates) {
      $targets = @($remaining | Where-Object { $_.Name -ne $cand.Name })
      $trial = @{}; foreach ($t in $targets) { $trial[$t.Name] = @{ Cpu = $load[$t.Name].Cpu; Mem = $load[$t.Name].Mem; Pods = $load[$t.Name].Pods } }
      $assign = @{}; $ok = $true
      foreach ($p in ($movable[$cand.Name] | Sort-Object Cpu, Mem -Descending)) {
        $dest = $targets | Where-Object {
          $trial[$_.Name].Cpu + $p.Cpu -le $_.Cpu * $util -and $trial[$_.Name].Mem + $p.Mem -le $_.Mem * $util -and $trial[$_.Name].Pods + 1 -le $_.MaxPods * $util
        } | Sort-Object { $_.Cpu - $trial[$_.Name].Cpu } -Descending | Select-Object -First 1
        if (-not $dest) { $ok = $false; break }
        $trial[$dest.Name].Cpu += $p.Cpu; $trial[$dest.Name].Mem += $p.Mem; $trial[$dest.Name].Pods += 1
        $assign[$p.Name] = $dest.Name
      }
      if ($ok) {
        [void]$plan.Add([pscustomobject]@{ Node = $cand.Name; Moves = $movable[$cand.Name].Count; Targets = (($assign.Values | Sort-Object -Unique) -join ', ') })
        foreach ($t in $targets) { $load[$t.Name] = $trial[$t.Name]; $movable[$t.Name] = @($movable[$t.Name]) + @($movable[$cand.Name] | Where-Object { $assign[$_.Name] -eq $t.Name }) }
        $remaining = $targets
        $placed = $true
        break
      }
    }
    if (-not $placed) { break }
  }

  if ($plan.Count -eq 0) {
    Write-Host "`nNothing to drain: the pods do not fit on fewer nodes under $MaxUtilizationPercent% (or the pool is already at $MinNodes)." -ForegroundColor Yellow
    return
  }

  Write-Host "`nPlan:" -ForegroundColor Cyan
  $plan | ForEach-Object { "  drain {0}  ({1} pods -> {2})" -f $_.Node, $_.Moves, $_.Targets }
  Write-Host "  remaining nodes: $(($remaining.Name) -join ', ')"
  Write-Host "  Pods on the drained nodes restart and rehydrate; a node failure/reboot now affects every Materialize pod on the remaining node(s).`n" -ForegroundColor Yellow

  foreach ($step in $plan) {
    if (-not $PSCmdlet.ShouldProcess($step.Node, 'Cordon and drain')) { continue }
    $baseline = Get-PendingPods
    Write-Host "Draining $($step.Node)..." -ForegroundColor Cyan
    try {
      Invoke-Kubectl @('drain', $step.Node, '--ignore-daemonsets', "--timeout=$($DrainTimeoutSeconds)s") -ShowStderr | ForEach-Object { Write-Host "  $_" }
    } catch {
      Write-Warning "Drain failed: $($_.Exception.Message). Uncordoning $($step.Node)."
      Invoke-Kubectl @('uncordon', $step.Node) | Out-Null
      throw
    }

    $deadline = (Get-Date).AddSeconds($SettleSeconds)
    do {
      Start-Sleep -Seconds 5
      $newPending = @(Get-PendingPods | Where-Object { $baseline -notcontains $_ })
    } while ($newPending.Count -gt 0 -and (Get-Date) -lt $deadline)

    if ($newPending.Count -gt 0) {
      Write-Warning "Pods still Pending after $SettleSeconds s: $($newPending -join ', '). Uncordoning $($step.Node)."
      Invoke-Kubectl @('uncordon', $step.Node) | Out-Null
      throw "Consolidation stopped at $($step.Node)."
    }
    Write-Host "  $($step.Node) drained; no new Pending pods." -ForegroundColor Green
  }

  Write-Host "`nDone. The autoscaler should remove the empty node(s) in ~10-15 minutes." -ForegroundColor Green
  Write-Host "Check with: kubectl get nodes   |   kubectl -n kube-system get cm cluster-autoscaler-status -o yaml"
  Write-Host "To undo before removal: kubectl uncordon <node>"
}
finally {
  $env:KUBECONFIG = $prevKubeconfig
  if (Test-Path $kubeconfig) { Remove-Item $kubeconfig -Force -WhatIf:$false -ErrorAction SilentlyContinue }
}
