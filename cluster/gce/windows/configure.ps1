# Copyright 2019 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

<#
.SYNOPSIS
  Top-level script that runs on Windows nodes to join them to the K8s cluster.
#>

# IMPORTANT PLEASE NOTE:
# Any time the file structure in the `windows` directory changes, `windows/BUILD`
# and `k8s.io/release/lib/releaselib.sh` must be manually updated with the changes.
# We HIGHLY recommend not changing the file structure, because consumers of
# Kubernetes releases depend on the release structure remaining stable.

$ErrorActionPreference = 'Stop'

# Turn on tracing to debug
# Set-PSDebug -Trace 1

# Update TLS setting to enable Github downloads and disable progress bar to
# increase download speed.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

# Returns the GCE instance metadata value for $Key where key is an "attribute"
# of the instance. If the key is not present in the instance metadata returns
# $Default if set, otherwise returns $null.
function Get-InstanceMetadataAttribute {
  param (
    [parameter(Mandatory=$true)] [string]$Key,
    [parameter(Mandatory=$false)] [string]$Default
  )

  $url = ("http://metadata.google.internal/computeMetadata/v1/instance/" +
          "attributes/$Key")
  try {
    $client = New-Object Net.WebClient
    $client.Headers.Add('Metadata-Flavor', 'Google')
    return ($client.DownloadString($url)).Trim()
  }
  catch [System.Net.WebException] {
    if ($Default) {
      return $Default
    }
    else {
      Write-Host "Failed to retrieve value for $Key."
      return $null
    }
  }
}

# Fetches the value of $MetadataKey, saves it to C:\$Filename and imports it as
# a PowerShell module.
#
# Note: this function depends on common.psm1.
function FetchAndImport-ModuleFromMetadata {
  param (
    [parameter(Mandatory=$true)] [string]$MetadataKey,
    [parameter(Mandatory=$true)] [string]$Filename
  )

  $module = Get-InstanceMetadataAttribute $MetadataKey
  if (Test-Path C:\$Filename) {
    if (-not $REDO_STEPS) {
      Log-Output "Skip: C:\$Filename already exists, not overwriting"
      Import-Module -Force C:\$Filename
      return
    }
    Log-Output "Warning: C:\$Filename already exists, will overwrite it."
  }
  New-Item -ItemType file -Force C:\$Filename | Out-Null
  Set-Content C:\$Filename $module
  Import-Module -Force C:\$Filename
}

try {
  # Don't use FetchAndImport-ModuleFromMetadata for common.psm1 - the common
  # module includes variables and functions that any other function may depend
  # on.
  $module = Get-InstanceMetadataAttribute 'common-psm1'
  New-Item -ItemType file -Force C:\common.psm1 | Out-Null
  Set-Content C:\common.psm1 $module
  Import-Module -Force C:\common.psm1

  # TODO(pjh): update the function to set $Filename automatically from the key,
  # then put these calls into a loop over a list of XYZ-psm1 keys.
  FetchAndImport-ModuleFromMetadata 'k8s-node-setup-psm1' 'k8s-node-setup.psm1'

  Dump-DebugInfoToConsole
  Set-PrerequisiteOptions
  $kube_env = Fetch-KubeEnv

  if (Test-IsTestCluster $kube_env) {
    Log-Output 'Test cluster detected, installing OpenSSH.'
    FetchAndImport-ModuleFromMetadata 'install-ssh-psm1' 'install-ssh.psm1'
    InstallAndStart-OpenSsh
    StartProcess-WriteSshKeys
  }

  Set-EnvironmentVars
  Create-Directories
  Download-HelperScripts

  Create-DockerRegistryKey
  DownloadAndInstall-KubernetesBinaries
  Create-NodePki
  Create-KubeletKubeconfig
  Create-KubeproxyKubeconfig
  Set-PodCidr
  Configure-HostNetworkingService
  Configure-CniNetworking
  Configure-GcePdTools
  Configure-Kubelet

  Start-WorkerServices
  Log-Output 'Waiting 15 seconds for node to join cluster.'
  Start-Sleep 15
  Verify-WorkerServices
}
catch {
  Write-Host 'Exception caught in script:'
  Write-Host $_.InvocationInfo.PositionMessage
  Write-Host "Kubernetes Windows node setup failed: $($_.Exception.Message)"
  exit 1
}
