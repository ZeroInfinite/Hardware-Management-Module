#region Cached Items
$ProfileCache = @{}
$InteropCache = @{}
$ComputerEPRCache = @{}
$PCSVEPRCache = @{}
#endregion

#region Helper Functions

function New-CustomObject ([string] $typeName, [string[]] $propertyNames) {
    $Object = New-Object System.Management.Automation.PSObject
    $Object.PSObject.TypeNames[0] = $typeName
    foreach ($property in $propertyNames) {
        $Object | Add-Member -MemberType NoteProperty -Name $property -Value $null
    }
    $Object
}

# Profile Registration Profile allows for both scoping and central methodology
# This function abstracts the discovery logic.  Function takes in a Profile instance and resulting classname
function Get-CentralInstance {
    param (
        [Parameter(ParameterSetName="CimInstance",Position=0,Mandatory=$true,ValueFromPipeline=$true)][Microsoft.Management.Infrastructure.CimInstance] $Profile,
        [Parameter(Mandatory=$true)][string] $resultClassName)

    process {
        $target = $null

        # first, see if target instance is associated directly to profile
        $target = $Profile | Get-CimAssociatedInstance -ResultClassName $resultClassName

        # else, traverse profiles to find CIM_ComputerSystem instance and then target instance
        while ($target -eq $null) {
            foreach ($relatedProfile in $Profile | Get-CimAssociatedInstance -ResultClassName CIM_RegisteredProfile) {
                $computerSystem = $relatedProfile | Get-CimAssociatedInstance -ResultClassName CIM_ComputerSystem
                if ($computerSystem) {
                    $target = $computerSystem | Get-CimAssociatedInstance -ResultClassName $resultClassName
                    if ($target) { break }
                }
            }
        }

        $target
    }
}

function Get-CimReferencedInstance {
    param (
        [Parameter(ParameterSetName="CimInstance",Position=0,Mandatory=$true,ValueFromPipeline=$true)][Microsoft.Management.Infrastructure.CimInstance] $InputObject,
        [Microsoft.Management.Infrastructure.CimSession] $CimSession,
        [string] $ResultClassName = $null,
        [switch] $KeysOnly = $false)

    process {
        $opt = New-Object Microsoft.Management.Infrastructure.Options.CimOperationOptions

        if ($KeysOnly) {
            $opt.KeysOnly = $true
        }

        if ($ResultClassName.Length -eq 0) {
            [NullString] $ResultClassName = [NullString]::Value
        }

        if ($CimSession -eq $null) {
            $CimSession = Get-CimSession -InstanceId $InputObject.GetCimSessionInstanceId()
            if ($CimSession -eq $null) {
                Write-Error "CimSession missing"
            }
        }

        try {
            $CimSession.EnumerateReferencingInstances($InputObject.CimClass.CimSystemProperties.Namespace,
                $InputObject, $ResultClassName, [NullString]::Value, $opt)
        } catch [Microsoft.Management.Infrastructure.CimException] {
            # if we get this error, it means the managed node doesn't support this and we just return no instances
            if ($_.FullyQualifiedErrorId -ne "BadEnumeration") {
                throw $_
            }
        }
    }
}

# store interop namespace and registered profiles per cimsession instanceId
# since a single computer may have a BMC, we can't use the computer name as the key
# this will result in duplicate cache entries for the same managed node if multiple cimsessions point to it
# TODO: expire cache entries after sometime not being used
function Update-Cache {
    param (
        [Parameter(Position=0,Mandatory=$true)]
        [Microsoft.Management.Infrastructure.CimSession] $CimSession)

    process {
        $ErrorActionPreference = "SilentlyContinue"

        if ($ProfileCache.ContainsKey($CimSession.InstanceId)) {
            $ProfileCache.Remove($CimSession.InstanceId)
            $InteropCache.Remove($CimSession.InstanceId)
        }

        Write-Progress -Activity "Caching data from $($CimSession.ComputerName)" -CurrentOperation "CIM_RegisteredProfile"

        $foundInterop = $false
        # Note: Per DSP1033, I should really only need to check interop and root/interop, the managed node just needs to accept a preceded slash
        $interopNamespaces = "interop","root/interop","/interop","/root/interop"
        foreach ($ns in $interopNamespaces) {
            try {
                $profiles = Get-CimInstance -CimSession $cimsession CIM_RegisteredProfile -Namespace $ns -ErrorAction Stop
                $foundInterop = $true
                $InteropCache.Add($CimSession.InstanceId, $ns)
                break
            } catch [Microsoft.Management.Infrastructure.CimException] { 
                if ($_.Exception.HResult -eq 0x80131500) { #InvalidSelector fault
                    continue
                } else {
                    throw $_
                }
            }
        }
        if (-not $foundInterop) {
            write-warning "Target system $($CimSession.ComputerName) does not support interop namespace"
            return
        }

        $ProfileCache.Add($CimSession.InstanceId, $profiles)

        # find the CIM_ComputerSystem instance whether Central or Scoping Class methodology is used
        # to simplify, we assume there is only one CIM_ComputerSystem instance we want to manage per managed node
        # traverse each profile until one is associated to CIM_ComputerSystem
        # we want to use assoc filter if supported to reduce network, but will fall back to simple assoc traversal
        # and filter on the client
        #TODO: Support multi-blade systems that return multiple instances of CIM_ComputerSystem
        #TODO: Support returning CIM_ComputerSystem associated to specific CIM_RegisteredProfile
        $opt = New-Object Microsoft.Management.Infrastructure.Options.CimOperationOptions
        $opt.KeysOnly = $true

        $pcsvp = $profiles | ? {$_.RegisteredName -eq 'Physical Computer System View'}
        if ($pcsvp) {
            Write-Verbose "$($CimSession.ComputerName) supports Physical Computer System View Profile"
            $pcsv = $pcsvp | Get-CimAssociatedInstance -Association "CIM_ElementConformsToProfile" -ResultClassName "CIM_PhysicalComputerSystemView" -KeyOnly
            $PCSVEPRCache.Add($CimSession.InstanceId, $pcsv)
        }
        Write-Progress -Activity "Caching data from $($CimSession.ComputerName)" -CurrentOperation "CIM_ComputerSystem"
        $foundComputer = $false
        foreach ($profile in $profiles) { 
            $cs = $profile | Get-CimAssociatedInstance -Association "CIM_ElementConformsToProfile" -ResultClassName "CIM_ComputerSystem" -KeyOnly
            if ($cs -ne $null) {
                $ComputerEPRCache.Add($CimSession.InstanceId, $cs)
                $foundComputer = $true
                break
            }
        }
        if (-not $foundComputer) {
            Write-Warning "Could not find instance of CIM_ComputerSystem on $($CimSession.ComputerName)"
        }
        Write-Progress -Activity "Caching data from $($CimSession.ComputerName)" -Completed
    }
}

function Get-CacheComputerSystem ([Microsoft.Management.Infrastructure.CimSession] $CimSession, [switch] $PCSV = $false) {
    if (-not $InteropCache.ContainsKey($CimSession.InstanceId)) {
        Update-Cache $CimSession
    }

    # Need to retrieve it each time since actual instance properties may have changed
    if (-not $PCSV -and $ComputerEPRCache.ContainsKey($CimSession.InstanceId)) {
        Write-Verbose "Using Computer System Profile"
        $computerSystem = Get-CimInstance -CimSession $CimSession $ComputerEPRCache[$CimSession.InstanceId]
        $computerSystem.pstypenames.insert(0,"Microsoft.Management.Infrastructure.CimInstance#CIM_ComputerSystem")
        $computerSystem
    } elseif ($PCSVEPRCache.ContainsKey($CimSession.InstanceId)) {
        Write-Verbose "Using Physical Computer System View Profile"
        $computerSystem = Get-CimInstance -CimSession $CimSession $PCSVEPRCache[$CimSession.InstanceId]
        $computerSystem.pstypenames.insert(0,"Microsoft.Management.Infrastructure.CimInstance#CIM_ComputerSystem")
        $computerSystem
    }
}

function New-Enum ([string] $namespace, [string] $name, [string[]] $members) {
$code = @"
    namespace $namespace
    {
        public enum $name : int 
        {
            $($members -join ",`n")
        }
    }
"@

    Add-Type $code 
}

function Get-ValueFromMap{
    param (
        [string[]] $values,
        [int[]] $valueMap,
        [int] $value)

    process {
        
        $valueHashTable = @{}
        for($i = 0; $i -lt $values.Length; $i++)
        {
            $valueHashTable.Add($valueMap[$i], $values[$i])
        }
        
        if (-not $valueHashTable.Contains($value)) {
            return $value.ToString() + ":Undefined"
        }
        
        return $($valueHashTable[$value])
    }
}

function Get-ValueFromIndex([string[]] $values, [int] $value, [switch] $noValueNum, [switch] $noZero) {
    if ($value -eq 0 -and $noZero) {
        return
    }

    if (-not $noValueNum) {
        $valueNum = $value.ToString() + ":"
    }

    if ($value -gt $values.Length) {
        return "Undefined"
    }
    else {
        return $values[$value]
    }
}
#endregion

#region General CIM Profiles
function Get-RegisteredProfile {
    <#
    .Synopsis
        Returns CIM Profiles registered on the managed node
    .Description
        Returns instances of CIM_RegisteredProfile registered on the managed node based on the Profile Registration Profile.

        More details of the Profile Registration Profile can be found here:

        http://www.dmtf.org/standards/published_documents/DSP1033_1.0.pdf

    .Parameter CimSession
        Instance or array of instances of existing CimSession objects.  See New-CimSession help for details.
    .Parameter RegisteredName
        Find instances only matching the RegisteredName property such as "Base Desktop and Mobile".
    .Parameter RegisteredVersion
        Find instances only matching the RegisteredVersion property, "1.0" would match "1.0.0" as well as "1.0.1"
    .Parameter RegisteredOrganization
        Find instances only matching the RegisteredOrganization or OtherRegisteredOrganization property such as "DMTF"
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> # Create another CimSession to out-of-band DASH capable hardware using HTTPS and Basic
        PS C:\> $comp2 = New-CimSession -ComputerName comp2 -Authentication Basic -Credential $cred2 -port 664
        PS C:\> Get-RegisteredProfile -CimSession $comp1,$comp2 -RegisteredName "Base Desktop and Mobile" -RegisteredOrganization "DMTF"

        RegisteredName                      RegisteredOrganization OtherRegisteredOrganization    Registered PSComputerName
                                                                                                  Version
        --------------                      ---------------------- ---------------------------    ---------- --------------
        Base Desktop and Mobile             DMTF                                                  1.0.0      comp1
        Base Desktop and Mobile             DMTF                                                  1.0.0      comp2
    #>
    [CmdletBinding()]
    param (
        [Parameter(Position=0)][string] $RegisteredName,
        [Parameter(Position=1)][string] $RegisteredVersion,
        [Parameter(Position=2)][string] $RegisteredOrganization,
        [Microsoft.Management.Infrastructure.CimSession[]] $CimSession = ".")

    process {

        foreach ($system in $CimSession) {
            if (-not $ProfileCache.ContainsKey($system.InstanceId)) {
                Update-Cache $system
            }

            foreach($profile in $ProfileCache[$system.InstanceId]) {
                if ($RegisteredName -eq [String]::Empty -or $profile.RegisteredName -eq $RegisteredName)
                {
                    if ($RegisteredVersion -eq [String]::Empty -or $profile.RegisteredVersion -match $RegisteredVersion) {
                        if ($RegisteredOrganization -eq [String]::Empty -or $profile.RegisteredOrganizationName -match $RegisteredOrganization `
                            -or $profile.OtherRegisteredOrganization -match $RegisteredOrganization -or ($profile.RegisteredOrganization -eq 2 `
                            -and $RegisteredOrganization -match "DMTF")) {
                            # explicitly add type in case returned instance is derived so that formatting is applied
                            $profile.pstypenames.insert(0,"Microsoft.Management.Infrastructure.CimInstance#CIM_RegisteredProfile")
                            $profile
                        }
                    }
                }
            }
        }
    }
}
#endregion

#region Hardware Profiles
. New-Enum CIM PowerState "On","SleepLight","SleepDeep","PowerCycleSoft","OffHard","Hibernate","OffSoft", `
    "PowerCycleHard","MasterBusReset","DiagnosticInterrupt","OffSoftGraceful","OffHardGraceful", `
    "MasterBusResetGraceful","PowerCycleSoftGraceful","PowerCycleHardGraceful"

function Get-PowerState {
    <#
    .Synopsis
        Returns current power state for target object
    .Description
        Returns current power state of a CIM object if the managed endpoint supports the Power State Management Profile.

        More details of the Power State Management Profile can be found here:

        http://dmtf.org/sites/default/files/standards/documents/DSP1027_1.0.pdf

    .Parameter CimSession
        Instance or array of instances of existing CimSession objects.  See New-CimSession help for details.
    .Parameter TargetObject
        Instance to a specific CIM object that supports Power State Management.  
        If not supplied, the Computer System power state is returned with the CIM_ComputerSystem instance
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> # Create another CimSession to out-of-band DASH capable hardware using HTTPS and Basic
        PS C:\> $comp2 = New-CimSession -ComputerName comp2 -Authentication Basic -Credential $cred2 -port 664
        PS C:\> Get-PowerState -CimSession $comp1,$comp2

        Name            Dedicated       PowerState      EnabledState AvailablePower Roles           PSComputerName
                                                                     States
        ----            ---------       ----------      ------------ ---------      -----           --------------
        e00971c5-614... Desktop         Sleep-Deep      Quiesce      {}             Managed System  comp1
        ManagedSystem   Laptop          On              Enabled      {On, Power ...                 comp2
    #>
    
    [CmdletBinding(DefaultParametersetName="CimSession")]
    param (
        [Parameter(ParameterSetName="CimSession",Position=0)]
        [Microsoft.Management.Infrastructure.CimInstance] $TargetObject = $null,
        [Parameter(ParameterSetName="CimSession")]
        [Microsoft.Management.Infrastructure.CimSession[]] $CimSession = ".")

    process {
        $ErrorActionPreference = "Stop"

        $powerStates = "Undefined", "Undefined", "On", "Sleep-Light", "Sleep-Deep",
            "Power Cycle (Off-Soft)", "Off-Hard", "Hibernate (Off-Soft)", "Off-Soft",
            "Power cycle (Off-Hard)", "Master Bus Reset", "Diagnostic Interrupt (NMI)",
            "Off-Soft Graceful", "Off-Hard Graceful", "Master Bus Reset Graceful",
            "Power Cycle off-Soft Graceful", "Power Cycle Off-Hard Graceful"

        if ($TargetObject -ne $null -and $CimSession.Count -gt 1) {
            throw "TargetObject cannot be used if multiple CimSessions are used"
        }

        foreach ($system in $CimSession) {
            $powerStateProfile = Get-RegisteredProfile -CimSession $system -RegisteredName "Power State Management" -RegisteredOrganization DMTF
            if ($powerStateProfile -eq $null) {
                Write-Warning "$($system.ComputerName) does not support Power State Management Profile"
                continue
            }

            # need to retrieve this everytime since transient properties may have changed
            if ($TargetObject -eq $null) {
                $TargetObject = Get-CacheComputerSystem $system
            }

            $namespace = $TargetObject.CimClass.CimSystemProperties.Namespace
            $assocPowerMgmtSvc = $system.EnumerateReferencingInstances($namespace,$TargetObject,`
                "CIM_AssociatedPowerManagementService",[NullString]::value)
            if ($assocPowerMgmtSvc -eq $null)
            {
                Write-Warning "The remote endpoint did not return CIM_AssociatedPowerManagementService"
                return
            }
        
            $availablePowerStates = @()
            foreach ($availableState in $assocPowerMgmtSvc.AvailableRequestedPowerStates) {
                $availablePowerStates += Get-ValueFromIndex $powerStates $availableState
            }
            $TargetObject | Add-Member -MemberType NoteProperty -Name AvailablePowerStates -Value $availablePowerStates

            #TODO: Add support for Power Utilization Management Profile: PowerUtilizationModesSuported, PowerUtilizationMode, PowerAllocationLimit

            $TargetObject | Add-Member -MemberType NoteProperty -Name PowerState -Value $(Get-ValueFromIndex $powerStates $assocPowerMgmtSvc.PowerState)
            $TargetObject

            # need to reset TargetObject since you can't use the same object against different systems
            $TargetObject = $null
        }
    }
}

function Set-PowerState {
    <#
    .Synopsis
        Request a power state change
    .Description
        Change the power state of target CIM object if the managed endpoint supports the Power State Management Profile

        More details of the Power State Management Profile can be found here:

        http://dmtf.org/sites/default/files/standards/documents/DSP1027_1.0.pdf

    .Parameter CimSession
        Instance or array of instances of existing CimSession objects.  See New-CimSession help for details.
    .Parameter TargetObject
        Instance to a specific CIM object that supports Power State Management.  
        If not supplied, the Computer System power state is changed.
    .Parameter PowerState
        The requested new power state.  See [CIM.PowerState] enum for possible values
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> Set-PowerState -CimSession $comp1 -PowerState OffSoft

        Successfully requested power state change to 'OffSoft' on comp1
    #>
    [CmdletBinding(DefaultParametersetName="CimSession",SupportsShouldProcess=$true)]
    param (
        [Parameter(ParameterSetName="CimSession",Position=0,Mandatory=$true)]
        [Microsoft.Management.Infrastructure.CimSession[]] $CimSession = ".",
        [Parameter()]
        [Microsoft.Management.Infrastructure.CimInstance] $TargetObject = $null,
        [Parameter(Mandatory=$true)]
        [CIM.PowerState] $PowerState = $null)

    process {
        $ErrorActionPreference = "Stop"

        $returnValueMap = "0", "1", "2", "3", "4", "5", "6", "4096", "4097", "4098", "4099"
        $returnValues = "Completed with No Error", "Not Supported", "Unknown or Unspecified Error", `
          "Cannot complete within Timeout Period", "Failed", "Invalid Parameter", "In Use", `
          "Method Parameters Checked - Job Started", "Invalid State Transition", `
          "Use of Timeout Parameter Not Supported", "Busy"

        $powerStateValue = ([int]$powerState + 2) # map enum to CIM values, DMTF does not define values for 0 and 1

        foreach ($system in $CimSession) {
            $powerStateProfile = Get-RegisteredProfile -CimSession $system -RegisteredName "Power State Management" -RegisteredOrganization DMTF
            if ($powerStateProfile -eq $null) {
                write-warning "$($system.ComputerName) does not support Power State Management Profile"
                continue
            }
            
            if ($TargetObject -eq $null) {
                $TargetObject = Get-CacheComputerSystem $system
            }

            $namespace = $TargetObject.CimClass.CimSystemProperties.Namespace
            if ($PSCmdlet.ShouldProcess($system.ComputerName,"RequestPowerStateChange")) {
                if ($Force -or $PSCmdlet.ShouldContinue("","")) {
                    $powerMgmtSvcs = $TargetObject | Get-CimAssociatedInstance -ResultClassName "CIM_PowerManagementService"
                    # even if multiple instances are returned, we should be able to use any to change the power state, so just use the first one
                    # [ordered] is needed to force the provided arguments to be ordered in cases where the endpoint is doing strict validation
                    $out = Invoke-CimMethod -CimSession $system -InputObject $powerMgmtSvcs[0] -MethodName RequestPowerStateChange `
                        -Arguments ([ordered]@{PowerState=$powerStateValue;ManagedElement=[ref]$TargetObject})

                    #TODO: handle CIM_Job case
                    if ($out.ReturnValue -ne 0) {
                        Write-Warning "$($system.ComputerName) returned $(Get-ValueFromMap $returnValues $returnValueMap $out.ReturnValue)"
                    }

                    Write-Verbose "Successfully requested power state change to '$powerState' on $($system.ComputerName)"
                    # need to reset TargetObject since you can't use the same object against different systems
                }
            }
                        
            $TargetObject = $null
        }
    }
}

function Get-HardwareInventory {
    <#
    .Synopsis
        Returns hardware inventory
    .Description
        Returns hardware inventory from the managed node based on support for Physical Asset, CPU, and System Memory Profiles

        More details of the Physical Asset Profile can be found here:

        http://www.dmtf.org/sites/default/files/standards/documents/DSP1011_1.0.pdf

        More details of the CPU Profile can be found here:

        http://dmtf.org/sites/default/files/standards/documents/DSP1022_1.0.pdf

        More details of the System Memory Profile can be found here:

        http://dmtf.org/sites/default/files/standards/documents/DSP1026_1.0.pdf

    .Parameter CimSession
        Instance or array of instances of existing CimSession objects.  See New-CimSession help for details.
    .Parameter UseFullProfiles
        Switch to specify to use the DASH/SMASH Profiles instead of optimizing to use Physical Computer System View Profile (if supported).
        This switch should only be used for testing or troubleshooting.
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> Get-HardwareInventory -CimSession $comp1

        Manufacturer    Model                               SerialNumber Tag        Processor ProcessorFamily                          NumOfCPU NumOf TotalSystem PSComputerName
                                                                                    Speed                                              Cores    CPUs  Memory
        ------------    -----                               ------------ ---        --------- ---------------                          -------- ----- ----------- --------------
        Fabrikam Corp   Fabrikam20000                       AABBCCDD     F12345     3200      Fabrikam Processor Family                2        1     2147483648  comp1

        PS C:\> Get-HardwareInventory -CimSession $comp1 | Format-List

        Manufacturer               : Fabrikam Corp
        Model                      : Fabrikam20000
        PackageType                : Chassis/Frame
        SKU                        : ABCD1234
        SerialNumber               : AABBCCDD
        PartNumber                 : 
        Tag                        : F12345
        FRUInfoSupported           : 
        PlatformGUID               : E00971C5614311E1BBD85F1FA33E082E
        ProcessorCurrentClockSpeed : 3200
        ProcessorMaxClockSpeed     : 3200
        ProcessorFamily            : Fabrikam Processor Family
        NumberOfProcessorThreads   : 2
        NumberOfProcessorCores     : 2
        NumberOfProcessors         : 1
        TotalSystemMemory          : 2147483648
        ConsumableMemory           : 1876312064
        PSComputerName             : comp1

    #>
    
    [CmdletBinding(DefaultParametersetName="CimSession")]
    param (
        [Parameter(ParameterSetName="CimSession",Position=0)]
        [Microsoft.Management.Infrastructure.CimSession[]] $CimSession = ".",
        [switch] $UseFullProfiles = $false)

    process {
        $ErrorActionPreference = "Stop"

        $packageTypes = "Unknown", "Other", "Rack", "Chassis/Frame", "Cross Connect/Backplane", "Container/Frame Slot", `
          "Power Supply", "Fan", "Sensor", "Module/Card", "Port/Connector", "Battery", "Processor", "Memory", `
          "Power Source/Generator", "Storage Media Package (e.g., Disk or Tape Drive)", "Blade", "Blade Expansion"
        $cpuFamily = "Other", "Unknown", "8086", "80286", "80386", 
          "80486", "8087", "80287", "80387", "80487", 
          "Pentium(R) brand", 
          "Pentium(R) Pro", "Pentium(R) II", 
          "Pentium(R) processor with MMX(TM) technology", 
          "Celeron(TM)", "Pentium(R) II Xeon(TM)", "Pentium(R) III", 
          "M1 Family", "M2 Family", 
          "Intel(R) Celeron(R) M processor", 
          "Intel(R) Pentium(R) 4 HT processor", 
          "K5 Family", 
          "K6 Family", "K6-2", "K6-3", 
          "AMD Athlon(TM) Processor Family", 
          "AMD(R) Duron(TM) Processor", "AMD29000 Family", 
          "K6-2+", 
          "Power PC Family", "Power PC 601", "Power PC 603", 
          "Power PC 603+", "Power PC 604", "Power PC 620", 
          "Power PC X704", "Power PC 750", 
          "Intel(R) Core(TM) Duo processor", 
          "Intel(R) Core(TM) Duo mobile processor", 
          "Intel(R) Core(TM) Solo mobile processor", 
          "Intel(R) Atom(TM) processor", 
          "Alpha Family", 
          "Alpha 21064", "Alpha 21066", "Alpha 21164", 
          "Alpha 21164PC", "Alpha 21164a", "Alpha 21264", 
          "Alpha 21364", 
          "AMD Turion(TM) II Ultra Dual-Core Mobile M Processor Family", 
          "AMD Turion(TM) II Dual-Core Mobile M Processor Family", 
          "AMD Athlon(TM) II Dual-Core Mobile M Processor Family", 
          "AMD Opteron(TM) 6100 Series Processor", 
          "AMD Opteron(TM) 4100 Series Processor", 
          "AMD Opteron(TM) 6200 Series Processor", 
          "AMD Opteron(TM) 4200 Series Processor", 
          "AMD FX(TM) Series Processor", 
          "MIPS Family", 
          "MIPS R4000", "MIPS R4200", "MIPS R4400", "MIPS R4600", 
          "MIPS R10000", "AMD C-Series Processor", 
          "AMD E-Series Processor", "AMD A-Series Processor", 
          "AMD G-Series Processor", "AMD Z-Series Processor", 
          "SPARC Family", 
          "SuperSPARC", "microSPARC II", "microSPARC IIep", 
          "UltraSPARC", "UltraSPARC II", "UltraSPARC IIi", 
          "UltraSPARC III", "UltraSPARC IIIi", 
          "68040", 
          "68xxx Family", "68000", "68010", "68020", "68030", 
          "Hobbit Family", 
          "Crusoe(TM) TM5000 Family", "Crusoe(TM) TM3000 Family", 
          "Efficeon(TM) TM8000 Family", "Weitek", 
          "Itanium(TM) Processor", 
          "AMD Athlon(TM) 64 Processor Family", 
          "AMD Opteron(TM) Processor Family", 
          "AMD Sempron(TM) Processor Family", 
          "AMD Turion(TM) 64 Mobile Technology", 
          "Dual-Core AMD Opteron(TM) Processor Family", 
          "AMD Athlon(TM) 64 X2 Dual-Core Processor Family", 
          "AMD Turion(TM) 64 X2 Mobile Technology", 
          "Quad-Core AMD Opteron(TM) Processor Family", 
          "Third-Generation AMD Opteron(TM) Processor Family", 
          "AMD Phenom(TM) FX Quad-Core Processor Family", 
          "AMD Phenom(TM) X4 Quad-Core Processor Family", 
          "AMD Phenom(TM) X2 Dual-Core Processor Family", 
          "AMD Athlon(TM) X2 Dual-Core Processor Family", 
          "PA-RISC Family", 
          "PA-RISC 8500", "PA-RISC 8000", "PA-RISC 7300LC", 
          "PA-RISC 7200", "PA-RISC 7100LC", "PA-RISC 7100", 
          "V30 Family", 
          "Quad-Core Intel(R) Xeon(R) processor 3200 Series", 
          "Dual-Core Intel(R) Xeon(R) processor 3000 Series", 
          "Quad-Core Intel(R) Xeon(R) processor 5300 Series", 
          "Dual-Core Intel(R) Xeon(R) processor 5100 Series", 
          "Dual-Core Intel(R) Xeon(R) processor 5000 Series", 
          "Dual-Core Intel(R) Xeon(R) processor LV", 
          "Dual-Core Intel(R) Xeon(R) processor ULV", 
          "Dual-Core Intel(R) Xeon(R) processor 7100 Series", 
          "Quad-Core Intel(R) Xeon(R) processor 5400 Series", 
          "Quad-Core Intel(R) Xeon(R) processor", 
          "Dual-Core Intel(R) Xeon(R) processor 5200 Series", 
          "Dual-Core Intel(R) Xeon(R) processor 7200 Series", 
          "Quad-Core Intel(R) Xeon(R) processor 7300 Series", 
          "Quad-Core Intel(R) Xeon(R) processor 7400 Series", 
          "Multi-Core Intel(R) Xeon(R) processor 7400 Series", 
          "Pentium(R) III Xeon(TM)", 
          "Pentium(R) III Processor with Intel(R) SpeedStep(TM) Technology", 
          "Pentium(R) 4", "Intel(R) Xeon(TM)", 
          "AS400 Family", 
          "Intel(R) Xeon(TM) processor MP", 
          "AMD Athlon(TM) XP Family", "AMD Athlon(TM) MP Family", 
          "Intel(R) Itanium(R) 2", 
          "Intel(R) Pentium(R) M processor", 
          "Intel(R) Celeron(R) D processor", 
          "Intel(R) Pentium(R) D processor", 
          "Intel(R) Pentium(R) Processor Extreme Edition", 
          "Intel(R) Core(TM) Solo Processor", 
          "K7", 
          "Intel(R) Core(TM)2 Duo Processor", 
          "Intel(R) Core(TM)2 Solo processor", 
          "Intel(R) Core(TM)2 Extreme processor", 
          "Intel(R) Core(TM)2 Quad processor", 
          "Intel(R) Core(TM)2 Extreme mobile processor", 
          "Intel(R) Core(TM)2 Duo mobile processor", 
          "Intel(R) Core(TM)2 Solo mobile processor", 
          "Intel(R) Core(TM) i7 processor", 
          "Dual-Core Intel(R) Celeron(R) Processor", 
          "S/390 and zSeries Family", 
          "ESA/390 G4", "ESA/390 G5", "ESA/390 G6", 
          "z/Architectur base", 
          "Intel(R) Core(TM) i5 processor", 
          "Intel(R) Core(TM) i3 processor", 
          "VIA C7(TM)-M Processor Family", 
          "VIA C7(TM)-D Processor Family", 
          "VIA C7(TM) Processor Family", 
          "VIA Eden(TM) Processor Family", 
          "Multi-Core Intel(R) Xeon(R) processor", 
          "Dual-Core Intel(R) Xeon(R) processor 3xxx Series", 
          "Quad-Core Intel(R) Xeon(R) processor 3xxx Series", 
          "VIA Nano(TM) Processor Family", 
          "Dual-Core Intel(R) Xeon(R) processor 5xxx Series", 
          "Quad-Core Intel(R) Xeon(R) processor 5xxx Series", 
          "Dual-Core Intel(R) Xeon(R) processor 7xxx Series", 
          "Quad-Core Intel(R) Xeon(R) processor 7xxx Series", 
          "Multi-Core Intel(R) Xeon(R) processor 7xxx Series", 
          "Multi-Core Intel(R) Xeon(R) processor 3400 Series", 
          "AMD Opteron(TM) 3000 Series Processor", 
          "AMD Sempron(TM) II Processor Family", 
          "Embedded AMD Opteron(TM) Quad-Core Processor Family", 
          "AMD Phenom(TM) Triple-Core Processor Family", 
          "AMD Turion(TM) Ultra Dual-Core Mobile Processor Family", 
          "AMD Turion(TM) Dual-Core Mobile Processor Family", 
          "AMD Athlon(TM) Dual-Core Processor Family", 
          "AMD Sempron(TM) SI Processor Family", 
          "AMD Phenom(TM) II Processor Family", 
          "AMD Athlon(TM) II Processor Family", 
          "Six-Core AMD Opteron(TM) Processor Family", 
          "AMD Sempron(TM) M Processor Family", 
          "i860", "i960", 
          "Reserved (SMBIOS Extension)", 
          "Reserved (Un-initialized Flash Content - Lo)", "SH-3", 
          "SH-4", "ARM", "StrongARM", 
          "6x86", "MediaGX", 
          "MII", "WinChip", "DSP", "Video Processor", 
          "Reserved (For Future Special Purpose Assignment)", 
          "Reserved (Un-initialized Flash Content - Hi)"
        $cpuFamilyMap = "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", 
          "11", "12", "13", "14", 
          "15", "16", "17", "18", "19", "20", "21", 
          "24", "25", "26", "27", 
          "28", "29", "30", "31", "32", "33", "34", "35", "36", 
          "37", "38", "39", "40", "41", "42", "43", 
          "48", "49", "50", "51", 
          "52", "53", "54", "55", "56", "57", "58", "59", "60", 
          "61", "62", "63", 
          "64", 
          "65", "66", "67", "68", "69", "70", "71", "72", "73", 
          "74", 
          "80", "81", "82", 
          "83", "84", "85", "86", "87", "88", 
          "96", "97", "98", 
          "99", "100", "101", 
          "112", "120", "121", 
          "122", "128", "130", "131", "132", "133", "134", 
          "135", "136", "137", "138", "139", "140", 
          "141", "142", "143", 
          "144", "145", 
          "146", "147", "148", "149", "150", 
          "160", "161", 
          "162", "163", "164", "165", "166", "167", "168", "169", 
          "170", "171", "172", "173", "174", "175", 
          "176", "177", "178", "179", 
          "180", "181", 
          "182", "183", "184", "185", "186", "187", "188", "189", 
          "190", "191", "192", 
          "193", "194", "195", "196", "197", "198", "199", 
          "200", "201", "202", 
          "203", "204", "205", "206", 
          "210", "211", 
          "212", "213", "214", "215", "216", "217", "218", "219", 
          "221", "222", "223", "224", "228", "229", 
          "230", "231", "232", "233", "234", 
          "235", "236", "237", "238", "239", 
          "250", "251", "254", 
          "255", "260", "261", "280", "281", 
          "300", "301", "302", 
          "320", "350", "500", 
          "65534", "65535"

        foreach ($system in $CimSession) {
            $HWInventory = New-CustomObject -typeName "HW_HardwareInventory" -propertyNames @("Manufacturer","Model","PackageType",
                "SKU","Version","SerialNumber","PartNumber","AssetTag","FRUInfoSupported","PlatformGUID","ProcessorCurrentClockSpeed",
                "ProcessorMaxClockSpeed","ProcessorFamily","NumberOfProcessorThreads","NumberOfProcessorCores","NumberOfProcessors",
                "TotalSystemMemory","ConsumableMemory","PSComputerName","PSShowComputerName","MAC")

            $pcsvp = Get-RegisteredProfile -CimSession $system -RegisteredName "Physical Computer System View" -RegisteredVersion 1
            if (-not $UseFullProfiles -and $pcsvp) {
                $pcsv = Get-CacheComputerSystem $system -PCSV
                
                if ($pcsvp.ImplementedFeatures -contains "DMTF:PhysicalAssetView") {
                    $HWInventory.FRUInfoSupported = $pcsv.FRUInfoSupported
                    $HWInventory.Manufacturer = $pcsv.Manufacturer
                    $HWInventory.Model = $pcsv.Model
                    $HWInventory.SKU = $pcsv.SKU
                    $HWInventory.SerialNumber = $pcsv.SerialNumber
                    $HWInventory.Version = $pcsv.Version
                    $HWInventory.PartNumber = $pcsv.PartNumber
                }
                if ($pcsvp.ImplementedFeatures -contains "DMTF:CPUView") {
                    $HWInventory.ProcessorCurrentClockSpeed = $pcsv.ProcessorCurrentClockSpeed
                    $HWInventory.ProcessorMaxClockSpeed = $pcsv.ProcessorMaxClockSpeed
                    $HWInventory.ProcessorFamily = $(Get-ValueFromMap $cpuFamily $cpuFamilyMap $pcsv.ProcessorFamily)
                    $HWInventory.NumberOfProcessorThreads = $pcsv.NumberOfProcessorThreads
                    $HWInventory.NumberOfProcessorCores = $pcsv.NumberOfProcessorCores
                    $HWInventory.NumberOfProcessors = $pcsv.NumberOfProcessors
                }
                if ($pcsvp.ImplementedFeatures -contains "DMTF:SystemMemoryView") {
                    [Int64]$total = $pcsv.MemoryNumberOfBlocks * $pcsv.MemoryBlockSize
                    $HWInventory.TotalSystemMemory = $total
                    $total = $pcsv.MemoryConsumableBlocks * $pcsv.MemoryBlockSize
                    $HWInventory.ConsumableMemory = $total
                }
                if ($pcsvp.ImplementedFeatures -contains "DMTF:ComputerSystemView") {
                    $index = $pcsv.IdentifyingDescriptions.IndexOf("CIM:GUID")
                    if ($index -ge 0) {
                        $HWInventory.PlatformGUID = $pcsv.OtherIdentifyingInfo[$index]
                    }
                    $index = $pcsv.IdentifyingDescriptions.IndexOf("CIM:MAC")
                    if ($index -ge 0) {
                        $HWInventory.MAC = $pcsv.OtherIdentifyingInfo[$index]
                    }
                    $index = $pcsv.IdentifyingDescriptions.IndexOf("CIM:Tag")
                    if ($index -ge 0) {
                        $HWInventory.AssetTag = $pcsv.OtherIdentifyingInfo[$index]
                    }
                }
            } else {
                $computer = Get-CacheComputerSystem $system

                $assetProfile = Get-RegisteredProfile -CimSession $system -RegisteredName "Physical Asset" -RegisteredOrganization DMTF
                if ($assetProfile -eq $null) {
                    Write-Warning "$($system.ComputerName) does not support Physical Asset Profile"
                } else {
                    Write-Progress -Activity "Collecting Hardware Inventory..." -CurrentOperation "Physical Asset"
                    $chassis = $computer | Get-CimAssociatedInstance -ResultClassName "CIM_Chassis"
                    $HWInventory.Manufacturer = $chassis.Manufacturer
                    $HWInventory.Model = $chassis.Model
                    $HWInventory.PackageType = $(Get-ValueFromIndex $packageTypes $chassis.PackageType)
                    $HWInventory.SKU = $chassis.SKU
                    $HWInventory.SerialNumber = $chassis.SerialNumber
                    $HWInventory.PartNumber = $chassis.PartNumber
                    $HWInventory.AssetTag = $chassis.UserTracking

                    $assetCap = $chassis | Get-CimAssociatedInstance -ResultClassName "CIM_PhysicalAssetCapabilities"
                    $HWInventory.FRUInfoSupported = $assetCap.FRUInfoSupported
               
                    $compPkg = $computer | Get-CimReferencedInstance -ResultClassName "CIM_ComputerSystemPackage"
                    $HWInventory.PlatformGUID = $compPkg.PlatformGUID
                }
            
                $CPUProfile = Get-RegisteredProfile -CimSession $system -RegisteredName "CPU" -RegisteredOrganization DMTF
                if ($CPUProfile -eq $null) {
                    Write-Warning "$($system.ComputerName) does not support CPU Profile"
                } else {
                    Write-Progress -Activity "Collecting Hardware Inventory..." -CurrentOperation "Processor"
                    $cpus = $computer | Get-CimAssociatedInstance -ResultClassName "CIM_Processor"
                    $cpuCount = 0
                    foreach ($cpu in $cpus) {
                        $cpuCount++
                        $HWInventory.ProcessorCurrentClockSpeed = $cpu.CurrentClockSpeed
                        $HWInventory.ProcessorMaxClockSpeed = $cpu.MaxClockSpeed
                        $HWInventory.ProcessorFamily = $(Get-ValueFromMap $cpuFamily $cpuFamilyMap $cpu.Family)

                        $cpuCap = $cpu | Get-CimAssociatedInstance -ResultClassName "CIM_ProcessorCapabilities"
                        $HWInventory.NumberOfProcessorThreads = $cpuCap.NumberOfHardwareThreads
                        $HWInventory.NumberOfProcessorCores = $cpuCap.NumberOfProcessorCores
                        break #only support homogenous main CPU
                    }
                    $HWInventory.NumberOfProcessors = $cpuCount
                }

                $memoryProfile = Get-RegisteredProfile -CimSession $system -RegisteredName "System Memory" -RegisteredOrganization DMTF
                if ($memoryProfile -eq $null) {
                    Write-Warning "$($system.ComputerName) does not support System Memory Profile"
                } else {
                    Write-Progress -Activity "Collecting Hardware Inventory..." -CurrentOperation "System Memory"
                    $mem = $computer | Get-CimAssociatedInstance -ResultClassName "CIM_Memory"
                    [Int64]$totalMemory = $mem.NumberOfBlocks * $mem.BlockSize
                    $HWInventory.TotalSystemMemory = $totalMemory
                    [Int64]$consumableMemory = $mem.ConsumableBlocks * $mem.BlockSize
                    $HWInventory.ConsumableMemory = $consumableMemory
                }

                Write-Progress -Activity "Collecting Hardware Inventory..." -Completed
            }
            $HWInventory.PSComputerName = $system.ComputerName
            $HWInventory.PSShowComputerName = $true
            $HWInventory
        }
    }
}

function Get-SoftwareInventory {
    <#
    .Synopsis
        Returns software inventory
    .Description
        Returns software inventory from managed node based on support for Software Inventory profile
        For hardware devices, this typically means firmware/BIOS/EFI.

        More details of the Software Inventory Profile can be found here:

        http://dmtf.org/sites/default/files/standards/documents/DSP1023_1.0.pdf

    .Parameter CimSession
        Instance or array of instances of existing CimSession objects.  See New-CimSession help for details.
    .Parameter UseSoftwareInventoryProfile
        Switch to specify to use the Software Inventory Profile instead of optimizing to use Physical Computer System View Profile (if supported).
        This switch should only be used for testing or troubleshooting.
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> Get-SoftwareInventory -CimSession $comp1

        ElementName                                   Manufacturer              VersionString PSComputerName
        -----------                                   ------------              ------------- --------------
        System Firmware Information                   Fabrikam Corp             v01.15        comp1
        Management Controller Firmware Information    Fabrikam Corp             DASH 1.52.0.2 comp1
        Network Controller Firmware Information       Fabrikam Corp             3.80          comp1
        Network Controller Driver Information         Fabrikam Corp             15.2.0.5      comp1
    #>
    
    [CmdletBinding(DefaultParametersetName="CimSession")]
    param (
        [Parameter(ParameterSetName="CimSession",Position=0)]
        [Microsoft.Management.Infrastructure.CimSession[]] $CimSession = ".",
        [switch] $UseSoftwareInventoryProfile = $false)

    process {
        $ErrorActionPreference = "Stop"

        foreach ($system in $CimSession) {
            $pcsvp = Get-RegisteredProfile -CimSession $system -RegisteredName "Physical Computer System View" -RegisteredVersion 1
            if (-not $UseSoftwareInventoryProfile -and $pcsvp -and $pcsvp.ImplementedFeatures -contains "DMTF:SoftwareInventoryView") {
                $pcsv = Get-CacheComputerSystem $system -PCSV
                if (-not $UseSoftwareInventoryProfile -and $pcsv) {
                    Write-Verbose "Using Physical Computer System View"
                    New-CimInstance -Namespace "" -ClassName CIM_SoftwareIdentity -ClientOnly -Property @{
                        SoftwareElementName="BIOS";
                        Classifications=@(11);
                        ElementName="BIOS";
                        MajorVersion=$pcsv.CurrentBIOSMajorVersion;
                        MinorVersion=$pcsv.CurrentBIOSMinorVersion;
                        VersionString=$pcsv.CurrentBIOSVersionString;
                        PSComputerName=$system.ComputerName;
                        PSShowComputerName=$true;
                        CimSessionInstanceID=$system.InstanceId
                    }
                    New-CimInstance -Namespace "" -ClassName CIM_SoftwareIdentity -ClientOnly -Property @{
                        SoftwareElementName="Management Firmware";
                        Classifications=@(10);
                        ElementName="Management Firmware";
                        MajorVersion=$pcsv.CurrentManagementFirmwareMajorVersion;
                        MinorVersion=$pcsv.CurrentManagementFirmwareMinorVersion;
                        VersionString=$pcsv.CurrentManagementFirmwareVersionString;
                        PSComputerName=$system.ComputerName;
                        PSShowComputerName=$true;
                        CimSessionInstanceID=$system.InstanceId
                    }
                }
            } else {
                $computer = Get-CacheComputerSystem $system

                $softwareProfile = Get-RegisteredProfile -CimSession $system -RegisteredName "Software Inventory" -RegisteredOrganization DMTF
                if ($softwareProfile -eq $null) {
                    Write-Warning "$($system.ComputerName) does not support Software Inventory Profile"
                    continue
                } else {
                    foreach ($software in ($computer | Get-CimAssociatedInstance -Association "CIM_InstalledSoftwareIdentity" -ResultClassName "CIM_SoftwareIdentity")) {
                        $software.pstypenames.insert(0,"Microsoft.Management.Infrastructure.CimInstance#CIM_SoftwareIdentity")
                        $software
                    }
                }
            }
        }
    }
}

function Get-OSStatus {
    <#
    .Synopsis
        Returns current OS status
    .Description
        Returns current installed OS and status from managed node based on support for OS Status Profile

        More details of the OS Status Profile can be found here:

        http://dmtf.org/sites/default/files/standards/documents/DSP1029_1.0.pdf

    .Parameter CimSession
        Instance or array of instances of existing CimSession objects.  See New-CimSession help for details.
    .Parameter UseOSStatusProfile
        Switch to specify to use the OS Status Profile instead of optimizing to use Physical Computer System View Profile (if supported).
        This switch should only be used for testing or troubleshooting.
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> Get-OSStatus -CimSession $comp1

        OSType                         Version         EnabledState PSComputerName
        ------                         -------         ------------ --------------
        Microsoft Windows 7            6.1.7601        Quiesce      comp1

    #>
    
    [CmdletBinding(DefaultParametersetName="CimSession")]
    param (
        [Parameter(ParameterSetName="CimSession",Position=0)]
        [Microsoft.Management.Infrastructure.CimSession[]] $CimSession = ".",
        [switch] $UseOSStatusProfile = $false)

    process {
        $ErrorActionPreference = "Stop"

        foreach ($system in $CimSession) {
            $pcsvp = Get-RegisteredProfile -CimSession $system -RegisteredName "Physical Computer System View" -RegisteredVersion 1
            if (-not $UseOSStatusProfile-and $pcsvp -and $pcsvp.ImplementedFeatures -contains "DMTF:OSView") {
                $pcsv = Get-CacheComputerSystem $system -PCSV
                if (-not $UseOSStatusProfile -and $pcsv) {
                    Write-Verbose "Using Physical Computer System View"
                    New-CimInstance -Namespace "" -ClassName CIM_OperatingSystem -ClientOnly -Property @{
                        OSType=$pcsv.OSType;
                        EnabledState=$pcsv.OSEnabledState;
                        Version=$pcsv.OSVersion;
                        CimSessionInstanceID=$system.InstanceId
                    }
                }
            } else {
                $osProfile = Get-RegisteredProfile -CimSession $system -RegisteredName "OS Status" -RegisteredOrganization DMTF
                if ($osProfile -eq $null) {
                    Write-Warning "$($system.ComputerName) does not support OS Status Profile"
                    continue
                } else {
                    $computer = Get-CacheComputerSystem $system
                    foreach ($os in ($computer | Get-CimAssociatedInstance -Association "CIM_InstalledOS" -ResultClassName "CIM_OperatingSystem")) {
                        $os.pstypenames.insert(0,"Microsoft.Management.Infrastructure.CimInstance#CIM_OperatingSystem")
                        $os
                    }
                }
            }
        }
    }
}

function Get-ComputerSystem {
    <#
    .Synopsis
        Returns computer system
    .Description
        Returns computer system from managed node based on support for Base Desktop and Mobile, Base Server, or Computer System Profiles

        More details of the Computer System Profile can be found here:

        http://www.dmtf.org/sites/default/files/standards/documents/DSP1052_1.0.pdf

        More details of the Base Server Profile can be found here:

        http://www.dmtf.org/sites/default/files/standards/documents/DSP1004_1.0.pdf

        More details of the Base Desktop and Mobile Profile can be found here:

        http://www.dmtf.org/sites/default/files/standards/documents/DSP1058_1.0.pdf

    .Parameter CimSession
        Instance or array of instances of existing CimSession objects.  See New-CimSession help for details.
    .Parameter PCSV
        Switch to specify to use the Physical Computer System View Profile (PCSV) instead of DASH/SMASH Profiles.
        Since the Endpoint Reference (EPR) for the PCSV and CIM_ComputerSystem instances are cached, both
        should have similar performance, however, the CIM_ComputerSystem instance may have additional data
        that is not represented in PCSV.
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> # Create another CimSession to out-of-band DASH capable hardware using HTTPS and Basic
        PS C:\> $comp2 = New-CimSession -ComputerName comp2 -Authentication Basic -Credential $cred2 -port 664
        PS C:\> Get-ComputerSystem -CimSession $comp1,$comp2

        Name            Dedicated       PowerState      EnabledState AvailablePower Roles           PSComputerName
                                                                     States
        ----            ---------       ----------      ------------ ---------      -----           --------------
        e00971c5-614... Desktop                         Quiesce                     Managed System  comp1
        ManagedSystem   Laptop                          Enabled                                     comp2
    #>
    
    param (
        [Parameter(Position=0)]
        [Microsoft.Management.Infrastructure.CimSession[]] $CimSession = ".",
        [switch] $PCSV = $false)

    process {
        $ErrorActionPreference = "Stop"

        foreach ($system in $CimSession) {
            $baseProfile = Get-RegisteredProfile -CimSession $system -RegisteredName "Base Desktop and Mobile" -RegisteredOrganization DMTF
            if ($baseProfile -eq $null) {
                $baseProfile = Get-RegisteredProfile -CimSession $system -RegisteredName "Base Server" -RegisteredOrganization DMTF
                if ($baseProfile -eq $null) {
                    $baseProfile = Get-RegisteredProfile -CimSession $system -RegisteredName "Computer System" -RegisteredOrganization DMTF
                    if ($baseProfile -eq $null) {
                        $baseProfile = Get-RegisteredProfile -CimSession $system -RegisteredName "Physical Computer System View" -RegisteredOrganization DMTF
                        if ($baseProfile -eq $null) {
                            Write-Warning "$($system.ComputerName) does not support Base Desktop and Mobile, Base Server, Computer System Profile, or Physical Computer System View Profile"
                            continue
                        }
                    }
                }
            }

            if ($baseProfile -ne $null) {
                $params = @{}
                if ($PCSV) {
                    $params.Add("PCSV",$true)
                }
                $computerSystem = Get-CacheComputerSystem $system @params
                $computerSystem
            }
        }
    }
}

function Get-NumericSensor {
    <#
    .Synopsis
        Returns numeric sensors
    .Description
        Returns numeric sensors supported by the managed node based on suport of Sensors Profile

        More information about the Sensors Profile can be found here:

        http://dmtf.org/sites/default/files/standards/documents/DSP1009_1.1.pdf

    .Parameter CimSession
        Instance or array of instances of existing CimSession objects.  See New-CimSession help for details.
    .Parameter UseSensorProfile
        Switch to specify to use the Sensor Profile instead of optimizing to use Physical Computer System View Profile (if supported).
        This switch should only be used for testing or troubleshooting.
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> Get-NumericSensor -CimSession $comp1,$comp2

        ElementName                              Communication ComputedReading      SensorType         EnabledState       PSComputerName
                                                 Status
        -----------                              ------------- ---------------      ----------         ------------       --------------
        Numeric Sensor #1 (Tachometer)           Ok            300 RPM              Tachometer         Not Applicable     comp1
        Numeric Sensor #2 (Tachometer)           Ok            300 RPM              Tachometer         Not Applicable     comp1
        Numeric Sensor #3 (Chassis Temperature)  Ok            35 Degrees C         Temperature        Not Applicable     comp1
        Numeric Sensor #4 (CPU Temperature)      Ok            40 Degrees C         Temperature        Not Applicable     comp1
    #>
    
    [CmdletBinding(DefaultParametersetName="CimSession")]
    param (
        [Parameter(ParameterSetName="CimSession",Position=0)]
        [Microsoft.Management.Infrastructure.CimSession[]] $CimSession = ".",
        [switch] $UseSensorProfile = $false)

    process {
        $ErrorActionPreference = "Stop"

        foreach ($system in $CimSession) {
            $pcsvp = Get-RegisteredProfile -CimSession $system -RegisteredName "Physical Computer System View" -RegisteredVersion 1
            if (-not $UseSensorProfile -and $pcsvp -and $pcsvp.ImplementedFeatures -contains "DMTF:NumericSensorView") {
                $pcsv = Get-CacheComputerSystem $system -PCSV
                Write-Verbose "Using Physical Computer System View"
                $sensorProperties = "BaseUnits","Context","CurrentReading","CurrentState","ElementName",
                    "EnabledState","HealthState","LowerThresholdCritical","LowerThresholdFatal",
                    "LowerThresholdNonCritical","OtherSensorTypeDescription","PrimaryStatus",
                    "RateUnits","SensorType","UnitModifier","UpperThresholdCritical",
                    "UpperThresholdFatal","UpperThresholdNonCritical"
                $numSensors = $pcsv.NumericSensorElementName.Count
                for ($index = 0; $index -lt $numSensors; $index++ ) {
                    $cimsensor = New-CimInstance -ClassName CIM_NumericSensor -Namespace "" -ClientOnly
                    foreach ($property in $sensorProperties) {
                        $pcsvProperty = $pcsv.CimInstanceProperties.Item("NumericSensor" + $property)
                        $propertyValue = $null
                        if ($pcsvProperty.value) {
                            $propertyValue = $pcsvProperty.Value[$index]
                        }
                        if ($propertyValue) {
                            $cimProperty = [Microsoft.Management.Infrastructure.CimProperty]::Create($property, $propertyValue, 0)
                        } else {
                            $cimProperty = [Microsoft.Management.Infrastructure.CimProperty]::Create($property, $propertyValue, 
                                [Microsoft.Management.Infrastructure.CimType]::String, 0)
                        }
                        $cimsensor.CimInstanceProperties.Add($cimProperty)
                    }
                    $cimsensor | Add-Member -MemberType NoteProperty -Name CimSessionInstanceID -Value $system.InstanceId
                    $cimsensor | Add-Member -MemberType NoteProperty -Name PSComputerName -Value $system.ComputerName -Force
                    $cimsensor | Add-Member -MemberType NoteProperty -Name PSShowComputerName -Value $true -Force
                    $cimsensor
                }
            } else {
                $computer = Get-CacheComputerSystem $system
                $sensorProfile = Get-RegisteredProfile -CimSession $system -RegisteredName "Sensors" -RegisteredOrganization DMTF
                if ($sensorProfile -eq $null) {
                    Write-Warning "$($system.ComputerName) does not support Sensors Profile"
                    continue
                } else {
                    foreach ($sensor in ($computer | Get-CimAssociatedInstance -ResultClassName "CIM_NumericSensor")) {
                        $sensor.pstypenames.insert(0,"Microsoft.Management.Infrastructure.CimInstance#CIM_NumericSensor")
                        $sensor
                    }
                }
            }
        }
    }
}

function Get-BootOrder {
    <#
    .Synopsis
        Returns current boot sources
    .Description
        Returns current boot sources and their defined order from managed node based on support of Boot Control Profile

        More details about the Boot Control Profile can be found here:

        http://dmtf.org/sites/default/files/standards/documents/DSP1012_1.0.pdf

    .Parameter CimSession
        Instance or array of instances of existing CimSession objects.  See New-CimSession help for details.
    .Parameter Persistent
        If used, this switch will filter results to only show boot sources for setting persistent boot order.
    .Parameter BootString
        If used, the value of this parameter will be used to filter results against the StructuredBootString property.
    .Parameter UseBootControlProfile
        Switch to specify to use the Boot Control Profile instead of optimizing to use Physical Computer System View Profile (if supported).
        This switch should only be used for testing or troubleshooting.
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> Get-BootOrder -CimSession $comp1

        ElementName                    BootSupport          AssignedSequence     StructuredBootString           FailThroughSupp PSComputerName
                                                                                                                orted
        -----------                    -----------          ----------------     --------------------           --------------- --------------                                                       
        Boot Order (Hard Drive)        PersistentNext       2                    CIM:Hard-Disk:1                Yes             comp1
        Boot Order (CD-ROM)            PersistentNext       3                    CIM:CD/DVD:2                   Yes             comp1
        Boot Order (Network)           PersistentNext       4                    CIM:Network:3                  No              comp1
        Boot Order (USB Device)        PersistentNext       1                    CIM:USB:4                      Yes             comp1
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> Get-BootOrder -CimSession $comp1 -BootString network -Persistent

        ElementName                    BootSupport          AssignedSequence     StructuredBootString           FailThroughSupp PSComputerName
                                                                                                                orted
        -----------                    -----------          ----------------     --------------------           --------------- --------------                                                       
        Boot Order (Network)           PersistentNext       4                    CIM:Network:3                  No              comp1
    #>
    
    [CmdletBinding(DefaultParametersetName="CimSession")]
    param (
        [Parameter(ParameterSetName="CimSession",Position=0,ValueFromPipeLine=$true)]
        [Microsoft.Management.Infrastructure.CimSession[]] $CimSession = ".",
        [switch] $Persistent = $false,
        [string] $BootString = $null,
        [switch] $UseBootControlProfile = $false)

    process {
        $ErrorActionPreference = "Stop"

        $failThroughSupportedValues = "Unknown", "Is Supported", "Not Supported"
        $isNextValues = "Unknown", "Persistent", "OneTime", "OneTime" # the first OneTime means it's available to be reused for OneTime

        foreach ($system in $CimSession) {
            $pcsvp = Get-RegisteredProfile -CimSession $system -RegisteredName "Physical Computer System View" -RegisteredVersion 1
            if (-not $UseBootControlProfile -and $pcsvp -and $pcsvp.ImplementedFeatures -contains "DMTF:BootControlView") {
                $pcsv = Get-CacheComputerSystem $system -PCSV
                #TODO: persistant boot order not defined yet in PCSV schema
                if ($Persistent) {
                    Write-Warning "Physical Computer System View 1.0 doesn't support Persistent Boot Order.  Rerun cmdlet with -UseBootControlProfile switch if supported by device"
                    return $false
                }
                $bootStrings = $pcsv.StructuredBootString
                for ($i = 0; $i -lt $bootStrings.Count; $i++) {
                    $bootsource = New-CimInstance -Namespace "" -ClassName CIM_BootSourceSetting -ClientOnly -Property @{
                        ElementName=$null;BootSupport="OneTime";AssignedSequence=0;StructuredBootString=$bootStrings[$i];FailThroughSupported=$null;
                        PSComputerName=$system.ComputerName;PSShowComputerName=$true;CimSessionInstanceID=$system.InstanceId
                    }
                    if ($i -eq $pcsv.OneTimeBootSource) {
                        $bootsource.AssignedSequence=1
                    }
                    $bootsource
                }                
            } else {
                $bootProfile = Get-RegisteredProfile -CimSession $system -RegisteredName "Boot Control" -RegisteredOrganization DMTF
                if ($bootProfile -eq $null) {
                    write-warning "$($system.ComputerName) does not support Boot Control Profile"
                    continue
                }

                $computer = Get-CacheComputerSystem $system
                $bootService = $computer | Get-CimAssociatedInstance -Association "CIM_HostedService" -ResultClassName "CIM_BootService"            
                $bootConfigSettings = $computer | Get-CimAssociatedInstance -ResultClassName "CIM_BootConfigSetting"
                foreach ($bootConfigSetting in $bootConfigSettings) {

                    $bootOrderedComponents = $bootConfigSetting | Get-CimReferencedInstance -ResultClassName "CIM_OrderedComponent"
                    try {
                        $bootSources = $bootConfigSetting | Get-CimAssociatedInstance -ResultClassName "CIM_BootSourceSetting"
                    } catch [Microsoft.Management.Infrastructure.CimException] {
                        # if we get this error, it means the managed node doesn't support this, we'll just not use that instance
                        if ($_.FullyQualifiedErrorId -ne "HRESULT 0x8033801a,Microsoft.Management.Infrastructure.CimCmdlets.GetCimAssociatedInstanceCommand") {
                            throw $_
                        }
                        continue
                    }
                    $elementSettingData = $bootConfigSetting | Get-CimReferencedInstance -ResultClassName "CIM_ElementSettingData"
                    $isNext = Get-ValueFromIndex $isNextValues $elementSettingData.IsNext

                    $index = 0
                    :EnumerateBootSources
                    foreach ($bootSource in $bootSources) {
                        if ($Persistent -eq $true -and $elementSettingData.IsNext -ne 1) {
                            $index++
                            continue EnumerateBootSources;
                        }
                        if ($bootString.Length -gt 0 -and $bootSource.StructuredBootString -inotlike $bootString) {
                            $index++
                            continue EnumerateBootSources;
                        }
                        $bootSource | Add-Member -MemberType NoteProperty -Name BootSupport -Value $isNext
                        $bootSource | Add-Member -MemberType NoteProperty -Name AssignedSequence -Value $bootOrderedComponents[$index].AssignedSequence
                        $bootSource.pstypenames.insert(0,"Microsoft.Management.Infrastructure.CimInstance#CIM_BootSourceSetting")
                        $bootSource
                        $index++
                    }
                }
            }
        }
    }
}

function Set-BootOrder {
    <#
    .Synopsis
        Set boot order
    .Description
        Set persistant or next boot order for managed node based on support of Boot Control Profile

        More details about the Boot Control Profile can be found here:

        http://dmtf.org/sites/default/files/standards/documents/DSP1012_1.0.pdf

    .Parameter CimSession
        Instance or array of instances of existing CimSession objects.  See New-CimSession help for details.
    .Parameter BootOrder
        Ordered array of CIM_BootSourceSetting instances returned from Get-BootOrder
    .Parameter OneTime
        Use of this switch will set a single CIM_BootSourceSetting to use for next boot.
        If this switch is not used, the supplied order is persisted.
    .Parameter UseBootControlProfile
        Switch to specify to use the Boot Control Profile instead of optimizing to use Physical Computer System View Profile (if supported).
        This switch should only be used for testing or troubleshooting.
    .Example 
        Change persistent boot order
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> $bootSources = Get-BootOrder -CimSession $comp1
        PS C:\> $bootSources

        ElementName                    BootSupport          AssignedSequence     StructuredBootString           FailThroughSupp PSComputerName
                                                                                                                orted
        -----------                    -----------          ----------------     --------------------           --------------- --------------                                                       
        Boot Order (Hard Drive)        PersistentNext       2                    CIM:Hard-Disk:1                Yes             comp1
        Boot Order (CD-ROM)            PersistentNext       1                    CIM:CD/DVD:2                   Yes             comp1
        Boot Order (Network)           PersistentNext       4                    CIM:Network:3                  No              comp1
        Boot Order (USB Device)        PersistentNext       3                    CIM:USB:4                      Yes             comp1

        # Change order to USB, Hard Drive, CD-COM, then Network
        PS C:\> Set-BootOrder -CimSession $comp1 -BootOrder $bootSources[3],$bootSources[0],$bootsources[1],$bootSources[2]

        ElementName                    BootSupport          AssignedSequence     StructuredBootString           FailThroughSupp PSComputerName
                                                                                                                orted
        -----------                    -----------          ----------------     --------------------           --------------- --------------                                                       
        Boot Order (Hard Drive)        PersistentNext       2                    CIM:Hard-Disk:1                Yes             comp1
        Boot Order (CD-ROM)            PersistentNext       3                    CIM:CD/DVD:2                   Yes             comp1
        Boot Order (Network)           PersistentNext       4                    CIM:Network:3                  No              comp1
        Boot Order (USB Device)        PersistentNext       1                    CIM:USB:4                      Yes             comp1
    #>
    
    [CmdletBinding(DefaultParametersetName="CimSession",SupportsShouldProcess=$true)]
    param (
        [Parameter(ParameterSetName="CimSession",Position=0)]
        [Microsoft.Management.Infrastructure.CimSession] $CimSession = ".",
        [Parameter(Mandatory=$true)]
        [Microsoft.Management.Infrastructure.CimInstance[]] $bootOrder,
        [Switch]$OneTime = $false,
        [Switch]$UseBootControlProfile = $false)
        # TODO: add $bootSource parameterset for enum values: Hard-Disk, CD/DVD, Network, USB, etc...
        # TODO: add support for structured boot string

    process {
        $returnValues = "Completed with No Error", "Not Supported", "Unknown/Unspecified Error",
          "Busy", "Invalid Reference", "Invalid Parameter", "Access Denied"

        $errorActionPreference = "stop"
        
        foreach ($system in $CimSession) {
            $pcsvp = Get-RegisteredProfile -CimSession $system -RegisteredName "Physical Computer System View" -RegisteredVersion 1
            if (-not $UseBootControlProfile -and $pcsvp -and $pcsvp.ImplementedFeatures -contains "DMTF:BootControlView") {
                $pcsv = Get-CacheComputerSystem $system -PCSV
                #TODO: persistant boot order not defined yet in PCSV schema
                if (-not $OneTime) {
                    Write-Error "Physical Computer System View 1.0 doesn't support Persistent Boot Order.  Rerun cmdlet with -UseBootControlProfile switch if supported by device"
                }
                if ($bootOrder.Count -ne 1) {
                    Write-Error "Only one BootSource can be provided for OneTime boot"
                }
                if ($PSCmdlet.ShouldProcess($system.ComputerName,"SetOneTimeBoot")) {
                    if ($Force -or $PSCmdlet.ShouldContinue("","")) {
                        $out = Invoke-CimMethod -InputObject $pcsv -MethodName SetOneTimeBootSource -Arguments @{StructuredBootString=$bootOrder.StructuredBootString}
                        if ($out.ReturnValue -eq 0) {
                            Write-Verbose "Command completed successfully."
                        } elseif ($out.ReturnValue -eq 4096) {
                            # TODO: support CIM_Job
                        } else {
                            Write-Warning "$($system.ComputerName) returned $(Get-ValueFromIndex -values $returnValues -value $out.returnValue)"
                            continue
                        }
                    }
                }
            } else {
                $bootProfile = Get-RegisteredProfile -CimSession $system -RegisteredName "Boot Control" -RegisteredOrganization DMTF
                if ($bootProfile -eq $null) {
                    Write-Warning "$($system.ComputerName) does not support Boot Control Profile"
                    continue
                }
        
                $comp = Get-ComputerSystem $system

                $bootSvc = $comp | Get-CimAssociatedInstance -ResultClassName "CIM_BootService"
                # to see if the managed node supports changing the boot order, we need to check two things:
                # 1. if CIM_BootServiceCapabilities exists and BootConfigCapabilities property does not contain a 6
                # 2. if CIM_BootServiceCapabilities does not exist
                # TODO: We'll skip this since we can just try and fail

                $bootConfigSetting = $null
                $targetIsNext = 1 # Is Next
                if ($OneTime) {
                    $targetIsNext = 3 # Is Next For Single Use
                }

                # find config for next boot
                # we do it in a roundabout way since CIM_ComputerSystem may be associated to many elements via CIM_ElementSettingData
                # but we only want instances of type CIM_BootConfigSetting where CIM_ElementSettingData indicates it is next
                $nextBootConfig = $null
                $bcs = $comp | Get-CimAssociatedInstance -ResultClassName "CIM_BootConfigSetting"
                $esd = $bcs | Get-CimReferencedInstance -ResultClassName "CIM_ElementSettingData"
                foreach ($bootElementSettingData in $esd) {
                    if ($bootElementSettingData.IsNext -eq $targetIsNext) {
                        $nextBootConfig = Get-CimInstance $bootElementSettingData.SettingData -CimSession $system
                        break
                    }
                }
                if ($nextBootConfig -eq $null) { # if none found, try modifying instance of CIM_ElementSettingData where IsNext=2 to 1 or 3 as needed
                    foreach ($bootElementSettingData in $esd) {
                        $bootElementSettingData.IsNext = $targetIsNext
                        Set-CimInstance $bootElementSettingData -ErrorAction SilentlyContinue
                        if ($?) { # successful
                            $nextBootConfig = Get-CimInstance $bootElementSettingData.SettingData -CimSession $system
                        }
                        break # whether we were able to set to 2 or 3, we will just try since different implementations seem to act differ
                    }
                }
                if ($nextBootConfig -eq $null) {
                    Write-Warning "$($system.ComputerName) does not contain appropriate instance of boot config needed"
                    continue
                }

                $bootSourceEPRs = @()
                foreach ($bootSource in $bootOrder) {
                    $bootSourceEPRs += [ref]($bootSource)
                }

                if ($PSCmdlet.ShouldProcess($system.ComputerName,"ChangeBootOrder")) {
                    if ($Force -or $PSCmdlet.ShouldContinue("","")) {
                        $out = Invoke-CimMethod -CimSession $system -InputObject $nextBootConfig -MethodName ChangeBootOrder -Arguments @{Source=$bootSourceEPRs}
                        if ($out.ReturnValue -eq 0) {
                            Write-Verbose "Command completed successfully."
                        } elseif ($out.ReturnValue -eq 4096) {
                            # TODO: support CIM_Job
                        } else {
                            Write-Warning "$($system.ComputerName) returned $(Get-ValueFromIndex -values $returnValues -value $out.returnValue)"
                            continue
                        }
                    }
                }
            }
        }
    }
}

function Get-RecordLog {
    <#
    .Synopsis
        Returns record logs
    .Description
        Returns record logs from managed node based on support of Record Log Profile

        More details about the Record Log Profile can be found here:
        
        http://www.dmtf.org/sites/default/files/standards/documents/DSP1010_1.0.pdf
        http://www.dmtf.org/sites/default/files/standards/documents/DSP1010_2.0.pdf

    .Parameter CimSession
        Instance or array of instances of existing CimSession objects.  See New-CimSession help for details.
    .Parameter InstanceId
        Filter results to a specific record log with this InstanceId
    .Parameter UseRecordLogProfile
        Switch to specify to use the Record Log Profile instead of optimizing to use Physical Computer System View Profile (if supported).
        This switch should only be used for testing or troubleshooting.
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> Get-RecordLog -CimSession $comp1,$comp2

        ElementName                    CurrentNumber MaxNumber EnabledState    OverwritePolicy  PSComputerName
                                       OfRecords     OfRecords
        -----------                    ------------- --------- ------------    ---------------  --------------
        Event Log                      1             499       Enabled         WrapsWhenFull    comp1
    #>
    
    param (
        [Parameter(Position=0)]
        [Microsoft.Management.Infrastructure.CimSession[]] $CimSession = ".",
        [string] $InstanceId,
        [switch] $UseRecordLogProfile = $false)

    process {
        $ErrorActionPreference = "Stop"

        foreach ($system in $CimSession) {
            $pcsvp = Get-RegisteredProfile -CimSession $system -RegisteredName "Physical Computer System View" -RegisteredVersion 1
            if (-not $UseRecordLogProfile -and $pcsvp -and $pcsvp.ImplementedFeatures -contains "DMTF:RecordLogView") {
                $pcsv = Get-CacheComputerSystem $system -PCSV
                if (-not $UseRecordLogProfile -and $pcsv) {
                    Write-Verbose "Using Physical Computer System View"
                    $LogProperties = "InstanceID","MaxNumberOfRecords","CurrentNumberOfRecords","OverwritePolicy","State"
                    $numLogs = $pcsv.LogInstanceID.Count
                    for ($index = 0; $index -lt $numLogs; $index++ ) {
                        if ($InstanceId -eq "" -or ($InstanceId -eq $pcsv.LogInstanceID[$index])) {
                            $cimLog = New-CimInstance -ClassName CIM_RecordLog -ClientOnly
                            foreach ($property in $LogProperties) {
                                $pcsvProperty = $pcsv.CimInstanceProperties.Item("Log" + $property)
                                $propertyValue = $null
                                if ($pcsvProperty.value) {
                                    $propertyValue = $pcsvProperty.Value[$index]
                                }
                                if ($propertyValue) {
                                    $cimProperty = [Microsoft.Management.Infrastructure.CimProperty]::Create($property, $propertyValue, 0)
                                } else {
                                    $cimProperty = [Microsoft.Management.Infrastructure.CimProperty]::Create($property, $propertyValue, 
                                        [Microsoft.Management.Infrastructure.CimType]::String, 0)
                                }
                                $cimLog.CimInstanceProperties.Add($cimProperty)
                            }
                            $cimLog | Add-Member -MemberType NoteProperty -Name CimSessionInstanceID -Value $system.InstanceId
                            $cimLog | Add-Member -MemberType NoteProperty -Name PSComputerName -Value $system.ComputerName -Force
                            $cimLog | Add-Member -MemberType NoteProperty -Name PSShowComputerName -Value $true -Force
                            $cimLog
                        }
                    }
                }
            } else {
                $recordLogProfile = Get-RegisteredProfile -CimSession $system -RegisteredName "Record Log" -RegisteredVersion 1 -RegisteredOrganization DMTF
                if ($recordLogProfile -eq $null) {
                    Write-Warning "$($system.ComputerName) does not support Record Log Profile"
                    continue
                } else {
                    $namespace = $recordLogProfile.CimClass.CimSystemProperties.Namespace
                    foreach ($recordLog in ($recordLogProfile | Get-CimAssociatedInstance -Association "CIM_ElementConformsToProfile" -ResultClassName "CIM_RecordLog")) {
                        if ($InstanceId -eq "" -or ($InstanceId -eq $recordLog.InstanceID)) {
                            $recordLog.pstypenames.insert(0,"Microsoft.Management.Infrastructure.CimInstance#CIM_RecordLog")
                            $recordLog
                        }
                    }
                }
            }
        }
    }
}

function Clear-RecordLog {
    <#
    .Synopsis
        Clears a record log
    .Description
        Removes all entries from a specific record log from managed node based on support of Record Log Profile

        More details about the Record Log Profile can be found here:
        
        http://www.dmtf.org/sites/default/files/standards/documents/DSP1010_1.0.pdf
        http://www.dmtf.org/sites/default/files/standards/documents/DSP1010_2.0.pdf

    .Parameter CimSession
        Instance of an existing CimSession object.  See New-CimSession help for details.
    .Parameter CimRecordLog
        Target CIM_RecordLog instance to clear
    .Parameter InstanceID
        Target CIM_RecordLog instance based on InstanceID to clear
    .Parameter UseRecordLogProfile
        Switch to specify to use the Record Log Profile instead of optimizing to use Physical Computer System View Profile (if supported).
        This switch should only be used for testing or troubleshooting.
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> Get-RecordLog -CimSession $comp1 | Clear-RecordLog

        Record log 'OEM1:70.1' cleared successfully
    #>
    
    [CmdletBinding(DefaultParameterSetName="CimSession",SupportsShouldProcess=$true)]
    param (
        [Parameter(ParameterSetName="CIM_RecordLog",ValueFromPipeline=$true,Position=0,Mandatory=$true)][Alias("CimLog")]
        [Microsoft.Management.Infrastructure.CimInstance] $CimRecordLog = $null,
        [Parameter(ParameterSetName="CimSession",Mandatory=$true)]
        [Microsoft.Management.Infrastructure.CimSession] $CimSession,
        [Parameter(ParameterSetName="CimSession",Mandatory=$true)]
        [string] $InstanceID,
        [switch] $UseRecordLogProfile = $false
        )

    process {
        $ErrorActionPreference = "Stop"
        $returnValues = "No Error", "Clear operation is not supported", "Unknown Error"

        if ($CimSession) {
            if ($UseRecordLogProfile) {
                $CimRecordLog = Get-RecordLog -CimSession $CimSession -InstanceId $InstanceID -UseRecordLogProfile
            } else {
                $CimRecordLog = Get-RecordLog -CimSession $CimSession -InstanceId $InstanceID
            }
        } else {
            $CimSession = Get-CimSession -InstanceId ($CimRecordLog.GetCimSessionInstanceId())
        }


        if ($PSCmdlet.ShouldProcess($CimRecordLog.GetCimSessionComputerName(),"ClearLog")) {
            if ($Force -or $PSCmdlet.ShouldContinue("","")) {
                $pcsvp = Get-RegisteredProfile -CimSession $Cimsession -RegisteredName "Physical Computer System View" -RegisteredVersion 1
                if (-not $UseRecordLogProfile -and $pcsvp -and $pcsvp.ImplementedFeatures -contains "DMTF:RecordLogView") {
                    $pcsv = Get-CacheComputerSystem $CimSession -PCSV

                    if ($InstanceID -eq "") {
                        $InstanceID = $CimRecordLog.InstanceID
                    }

                    $out = Invoke-CimMethod -InputObject $pcsv -MethodName ClearLog -Arguments @{InstanceID=$InstanceID}
                } else {
                    $out = Invoke-CimMethod -InputObject $CimRecordLog -MethodName ClearLog
                }

                if ($out.ReturnValue -eq 0) {
                    Write-Verbose "Record log '$($CimRecordLog.InstanceId)' cleared successfully"
                } else {    
                    Write-Error "$($CimRecordLog.GetCimSessionComputerName()) returned $(Get-ValueFromIndex $returnValues $out.ReturnValue)"
                }
            }
        }
    }
}

function Get-LogEntry {
    <#
    .Synopsis
        Returns log entries for a specified record log
    .Description
        Returns log entries for a specified record log based on Record Log Profile

        More details about the Record Log Profile can be found here:
        
        http://www.dmtf.org/sites/default/files/standards/documents/DSP1010_1.0.pdf
        http://www.dmtf.org/sites/default/files/standards/documents/DSP1010_2.0.pdf

    .Parameter CimSession
        Instance of an existing CimSession object.  See New-CimSession help for details.
    .Parameter CimRecordLog
        Returns log entries associated to a specific instance of CIM_RecordLog
    .Parameter InstanceID
        Returns log entries associated to a specific instance of CIM_RecordLog based on InstanceID
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> Get-RecordLog -CimSession $comp1 | Get-LogEntry

        CreationTimeStamp : 7/30/2012 11:27:47 AM
        ElementName       : Event Log Entry 3
        InstanceID        : OEM1:71.1.3
        LogInstanceID     : OEM1:70.1
        LogName           : Event Log
        MessageArguments  : Event Log
        MessageID         : PLAT0200
        OwningEntity      : DMTF
        PerceivedSeverity : 2
        RecordData        :     DMTF    PLAT0200    Event Log            2    3    2    //OEM/implementation:CIM_RecordLog.InstanceID="OEM1:70.1"
        RecordFormat      :     string CIM_AlertIndication.OwningEntity    string CIM_AlertIndication.MessageID    string CIM_AlertIndication.MessageArguments[0]    string 
                            CIM_AlertIndication.MessageArguments[1]    string CIM_AlertIndication.MessageArguments[2]    uint16 CIM_AlertIndication.PerceivedSeverity    uint16 
                            CIM_AlertIndication.AlertType    uint16 CIM_AlertIndication.AlertingElementFormat    string CIM_AlertIndication.AlertingManagedElement
        RecordID          : 3
        PSComputerName    : comp1
    #>
    
    [CmdletBinding(DefaultParameterSetName="CimSession")]
    param (
        [Parameter(ParameterSetName="CIM_RecordLog",ValueFromPipeline=$true,Position=0,Mandatory=$true)][Alias("CimLog")]
        [Microsoft.Management.Infrastructure.CimInstance] $CimRecordLog = $null,
        [Parameter(ParameterSetName="CimSession",Mandatory=$true)]
        [Microsoft.Management.Infrastructure.CimSession] $CimSession,
        [Parameter(ParameterSetName="CimSession",Mandatory=$true)]
        [string] $InstanceID        
        )

    process {
        $ErrorActionPreference = "Stop"

        if ($CimSession) {
            $CimRecordLog = Get-RecordLog -CimSession $CimSession -InstanceId $InstanceID -UseRecordLogProfile
        } elseif ($CimRecordLog.CimSessionInstanceID) {
            $CimRecordLog = Get-RecordLog -CimSession (Get-CimSession -InstanceId $CimRecordLog.CimSessionInstanceID) -InstanceId $CimRecordLog.InstanceID -UseRecordLogProfile
        }

        foreach ($logEntry in ($CimRecordLog | Get-CimAssociatedInstance -ResultClassName "CIM_LogEntry")) {
            #TODO: Format log entries based on Platform Alert Message Registry
            $logEntry.pstypenames.insert(0,"Microsoft.Management.Infrastructure.CimInstance#CIM_LogEntry")
            $logEntry
        }
    }
}

function Get-ConsoleRedirection {
    <#
    .Synopsis
        Returns current console redirection configuration for managed endpoint
    .Description
        Returns current console redirection configuration for the managed endpoint supports the Text Console Redirection Profile.
        Depending on the hardware support, you will need to use a seperate client (Telnet or SSH, for example) to connect to the redirected console.

        More details of the Text Console Redirection Profile can be found here:

        http://dmtf.org/sites/default/files/standards/documents/DSP1024_1.0.pdf

    .Parameter CimSession
        Instance or array of instances of existing CimSession objects.  See New-CimSession help for details.
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> Get-ConsoleRedirection -CimSession $comp1

        ElementName                                                          EnabledState         Port  PSComputerName
        -----------                                                          ------------         ----  --------------
        Text Redirection SAP for the Telnet Service                          Enabled but Offline  87    comp1
        Text Redirection SAP for the SSH Service                             Disabled             57    comp1
    #>
    
    [CmdletBinding(DefaultParametersetName="CimSession")]
    param (
        [Parameter(ParameterSetName="CimSession")]
        [Microsoft.Management.Infrastructure.CimSession[]] $CimSession = ".")

    process {
        $ErrorActionPreference = "Stop"

        foreach ($system in $CimSession) {
            $consoleProfile = Get-RegisteredProfile -CimSession $system -RegisteredName "Text Console Redirection" -RegisteredOrganization DMTF
            if ($consoleProfile -eq $null) {
                Write-Warning "$($system.ComputerName) does not support Text Console Redirection Profile"
                continue
            }

            $redirectionService = $consoleProfile | Get-CentralInstance -resultClassName CIM_TextRedirectionService
            if ($redirectionService -eq $null) {
                Write-Warning "$($system.ComputerName) did not return instance of CIM_TextRedirectionService"
                continue
            }

            foreach ($redirectionSAP in $redirectionService | Get-CimAssociatedInstance -ResultClassName CIM_TextRedirectionSAP) {
                foreach ($tcpEndpoint in $redirectionSAP | Get-CimAssociatedInstance -ResultClassName CIM_TCPProtocolEndpoint) {
                    #TODO:currently assume only one endpoint per SAP
                    $redirectionSAP | Add-Member -MemberType NoteProperty -Name Port -Value $tcpEndpoint.PortNumber
                }
                $redirectionSAP.pstypenames.insert(0,"Microsoft.Management.Infrastructure.CimInstance#CIM_TextRedirectionSAP")
                $redirectionSAP
            }
        }
    }
}

#endregion

#region AuthManagement
function Get-Account {
    <#
    .Synopsis
        Returns user accounts on the target system
    .Description
        Returns user accounts if the managed endpoint supports the Simple Identity Management Profile.

        More details of the Simple Identity Management Profile can be found here:

        http://dmtf.org/sites/default/files/standards/documents/DSP1034_1.0.pdf

    .Parameter CimSession
        Instance or array of instances of an existing CimSession objects.  See New-CimSession help for details.
    .Parameter UserID
        Filter results for an account matching the specified UserID
    .Parameter CimAccount
        Retrieve the current instance of the specified accounts
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> Get-Account -CimSession $comp1

        Name          UserID        EnabledState RequestedStatesSupported                 Role                                     PSComputerName
        ----          ------        ------------ ------------------------                 ----                                     --------------
        User:1        Administrator Enabled      {Enabled, Offline}                       {Operator Role}                          comp1
        User:2        Operator      Offline      {Enabled, Offline}                       {Operator Role}                          comp1
        User:3        Auditor       Enabled      {Enabled, Offline}                       {Read Only Role, Auditor Role}           comp1
    #>
    
    [CmdletBinding(DefaultParametersetName="UserID")]
    param (
        [Parameter(ParameterSetName="CimSession")]
        [Microsoft.Management.Infrastructure.CimSession[]] $CimSession = ".",
        [Parameter(ParameterSetName="CimSession")]
        [string] $UserID,
        [Parameter(ParameterSetName="CimAccount",ValueFromPipeLine=$true)]
        [Microsoft.Management.Infrastructure.CimInstance[]] $CimAccount = $null
        )

    process {
        $ErrorActionPreference = "Stop"

        $refresh = $false
        if ($CimAccount.Count -eq 0) {
            foreach ($system in $CimSession) {
                Write-Progress -Activity "Enumerating accounts from $($CimSession.ComputerName)" -CurrentOperation "CIM_Account"

                $simpleIdentityProfile = Get-RegisteredProfile -CimSession $system -RegisteredName "Simple Identity Management" -RegisteredOrganization DMTF
                if ($simpleIdentityProfile -eq $null) {
                    Write-Warning "$($system.ComputerName) does not support Simple Identity Management Profile"
                    continue
                }

                $accountMgmtSvc = $simpleIdentityProfile | Get-CentralInstance -ResultClassName CIM_AccountManagementService
                if ($accountMgmtSvc -eq $null) {
                    Write-Warning "$($system.ComputerName) did not return CIM_AccountManagementService"
                    continue
                }

                $rbap = Get-RegisteredProfile -CimSession $system -RegisteredName "Role Based Authorization" -RegisteredOrganization DMTF
                if ($rbap -eq $null) {
                    Write-Warning "$($system.ComputerName) does not support Role Based Authorization Profile"
                    continue
                }

                $roleMgmtSvc = $rbap | Get-CentralInstance -resultClassName CIM_RoleBasedAuthorizationService
                if ($roleMgmtSvc -eq $null) {
                    Write-Warning "$($system.ComputerName) did not return CIM_RoleBasedAuthorizationService"
                    continue
                }

                $cs = $accountMgmtSvc | Get-CimAssociatedInstance -ResultClassName CIM_ComputerSystem
                if ($cs -eq $null) {
                    Write-Warning "$($system.ComputerName) did not return CIM_ComputerSystem associated to CIM_AccountManagementService"
                    continue
                }
                $CimAccount += $cs | Get-CimAssociatedInstance -ResultClassName CIM_Account
            }
        } else {
            $refresh = $true
        }

        foreach ($account in $CimAccount) {
            if ($refresh) {
                $account = $account | Get-CimInstance
            }

            if ($UserID.Length -gt 0 -and $account.UserId -ne $UserID) {
                continue
            }

            $cap = $account | Get-CimAssociatedInstance -ResultClassName CIM_EnabledLogicalElementCapabilities
            if ($cap -ne $null) {
                $account | Add-Member -Force -MemberType NoteProperty -Name RequestedStatesSupported -Value $cap.RequestedStatesSupported
            }

            $identities = @()
            $roles = @()
            Write-Progress -Activity "Getting identity and roles for $($account.Name)" -CurrentOperation "CIM_Role"

            foreach ($identity in $account | Get-CimAssociatedInstance -ResultClassName CIM_Identity) {
                $identities += $identity.ElementName

                foreach ($role in $identity | Get-CimAssociatedInstance -ResultClassName CIM_Role) {
                    $roles += $role.ElementName
                }
            }
            $account | Add-Member -Force -MemberType NoteProperty -Name Identity -Value $identities
            $account | Add-Member -Force -MemberType NoteProperty -Name Role -Value $roles
            $account.pstypenames.insert(0,"Microsoft.Management.Infrastructure.CimInstance#CIM_Account")
            $account
            Write-Progress -Activity "Getting identity and roles for $($account.Name)" -Completed
        }
    }
}

function Get-AccountMgmtService {
    <#
    .Synopsis
        Returns instances of the Account Management Services of the managed endpoint
    .Description
        Returns instances of the Account Management Services of the managed endpoint if the managed endpoint supports the Simple Identity Management Profile.
        This is only needed if the managed endpoint has different Account Management Services for different accounts (for example, IPMI vs WS-Man)

        More details of the Simple Identity Management Profile can be found here:

        http://dmtf.org/sites/default/files/standards/documents/DSP1034_1.0.pdf

    .Parameter CimSession
        Instance or array of instances of an existing CimSession objects.  See New-CimSession help for details.
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> Get-AccountMgmtService -CimSession $comp1

        ElementName                    Name                                     PSComputerName
        -----------                    ----                                     --------------
        Local User Account Manageme... LocalUserAccountManagementService        comp1
        IPMI Account Management Ser... IPMIAccountManagementService             comp1
        CLP Account Management Service CLPAccountManagementService              comp1
    #>
    
    [CmdletBinding(DefaultParametersetName="CimSession")]
    param (
        [Parameter(ParameterSetName="CimSession")]
        [Microsoft.Management.Infrastructure.CimSession[]] $CimSession = ".")

    process {
        $ErrorActionPreference = "Stop"

        foreach ($system in $CimSession) {
            $simpleIdentityProfile = Get-RegisteredProfile -CimSession $system -RegisteredName "Simple Identity Management" -RegisteredOrganization DMTF
            if ($simpleIdentityProfile -eq $null) {
                Write-Warning "$($system.ComputerName) does not support Simple Identity Management Profile"
                continue
            }

            foreach ($accmgmtsvc in $simpleIdentityProfile | Get-CentralInstance -ResultClassName CIM_AccountManagementService) {
                $accmgmtsvc.pstypenames.insert(0,"Microsoft.Management.Infrastructure.CimInstance#CIM_AccountManagementService")
                $accmgmtsvc
            }
        }
    }
}

# internally used function
function Set-AccountState {
    [CmdletBinding(DefaultParametersetName="CimAccount")]
    param (
        [Parameter(ParameterSetName="CimAccount",ValueFromPipeLine=$true)]
        [Microsoft.Management.Infrastructure.CimInstance] $CimAccount,
        [int] $RequestedState)

    process {
        $returnValues = "Completed with No Error", "Not Supported", "Unknown or Unspecified Error", 
        "Cannot complete within Timeout Period", "Failed", "Invalid Parameter", "In Use"

        $ErrorActionPreference = "Stop"
        if (-not $cimAccount.pstypenames.contains("Microsoft.Management.Infrastructure.CimInstance#CIM_Account")) {
            Write-Error "Only instances of type Microsoft.Management.Infrastructure.CimInstance#CIM_Account may be used"
        }

        $out = Invoke-CimMethod -InputObject $cimAccount -MethodName RequestStateChange -Arguments @{RequestedState=$RequestedState}
        if ($out.ReturnValue -eq 0) {
            Write-Verbose "Command completed successfully."
        } elseif ($out.ReturnValue -eq 4096) {
            # TODO: support CIM_Job
            Write-Warning "$($CimAccount.CimSystemProperties.ServerName) accepted the request and returned a CIM_Job"
        } else {
            Write-Warning "$($CimAccount.CimSystemProperties.ServerName) returned $(Get-ValueFromIndex -values $returnValues -value $out.returnValue) ($($out.returnValue))"
            continue
        }
    }
}

function Enable-Account {
    <#
    .Synopsis
        Enable an account on the target system
    .Description
        Requests that the state of an account be set to enabled.

        More details of the Simple Identity Management Profile can be found here:

        http://dmtf.org/sites/default/files/standards/documents/DSP1034_1.0.pdf

    .Parameter CimAccount
        Instance of an existing CIM_Account object.  See Get-Account help for details.
    .Parameter CimSession
        Instance of an existing CimSession object.  See New-CimSession help for details.
    .Parameter UserID
        Used with CimSession to identify a specific account
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> Get-Account -CimSession $comp1 -UserId Administrator | Enable-Account
    #>
    
    [CmdletBinding(DefaultParametersetName="CimSession")]
    param (
        [Parameter(ParameterSetName="CimAccount",ValueFromPipeLine=$true)]
        [Microsoft.Management.Infrastructure.CimInstance] $CimAccount,
        [Parameter(ParameterSetName="CimSession",Mandatory=$true)]
        [Microsoft.Management.Infrastructure.CimSession] $CimSession,
        [Parameter(ParameterSetName="CimSession",Mandatory=$true)]
        [string] $UserID        
        )

    process {
        $ErrorActionPreference = "Stop"

        if ($CimSession) {
            $CimAccount = Get-Account -CimSession $CimSession -UserID $UserID
        }

        if (-not $cimAccount.pstypenames.contains("Microsoft.Management.Infrastructure.CimInstance#CIM_Account")) {
            Write-Error "Only instances of type Microsoft.Management.Infrastructure.CimInstance#CIM_Account may be used"
        }

        Set-AccountState -CimAccount $CimAccount -RequestedState 2
    }
}

function Disable-Account {
    <#
    .Synopsis
        Disable an account on the target system
    .Description
        Requests that the state of an account be set to disabled.

        More details of the Simple Identity Management Profile can be found here:

        http://dmtf.org/sites/default/files/standards/documents/DSP1034_1.0.pdf

    .Parameter CimAccount
        Instance of an existing CIM_Account object.  See Get-Account help for details.
    .Parameter CimSession
        Instance of an existing CimSession object.  See New-CimSession help for details.
    .Parameter UserID
        Used with CimSession to identify a specific account
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> Get-Account -CimSession $comp1 -UserId Administrator | Disable-Account
    #>
    
    [CmdletBinding(DefaultParametersetName="CimSession")]
    param (
        [Parameter(ParameterSetName="CimAccount",ValueFromPipeLine=$true)]
        [Microsoft.Management.Infrastructure.CimInstance] $CimAccount,
        [Parameter(ParameterSetName="CimSession",Mandatory=$true)]
        [Microsoft.Management.Infrastructure.CimSession] $CimSession,
        [Parameter(ParameterSetName="CimSession",Mandatory=$true)]
        [string] $UserID        
        )

    process {
        $ErrorActionPreference = "Stop"

        if ($CimSession) {
            $CimAccount = Get-Account -CimSession $CimSession -UserID $UserID
        }

        if (-not $cimAccount.pstypenames.contains("Microsoft.Management.Infrastructure.CimInstance#CIM_Account")) {
            Write-Error "Only instances of type Microsoft.Management.Infrastructure.CimInstance#CIM_Account may be used"
        }

        Set-AccountState -CimAccount $CimAccount -RequestedState 3
    }
}

function Suspend-Account {
    <#
    .Synopsis
        Suspends an account on the target system
    .Description
        Requests that the state of an account be set to offline.

        More details of the Simple Identity Management Profile can be found here:

        http://dmtf.org/sites/default/files/standards/documents/DSP1034_1.0.pdf

    .Parameter CimAccount
        Instance of an existing CIM_Account object.  See Get-Account help for details.
    .Parameter CimSession
        Instance of an existing CimSession object.  See New-CimSession help for details.
    .Parameter UserID
        Used with CimSession to identify a specific account
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> Get-Account -CimSession $comp1 -UserId Administrator | Suspend-Account
    #>
    
    [CmdletBinding(DefaultParametersetName="CimSession")]
    param (
        [Parameter(ParameterSetName="CimAccount",ValueFromPipeLine=$true)]
        [Microsoft.Management.Infrastructure.CimInstance] $CimAccount,
        [Parameter(ParameterSetName="CimSession",Mandatory=$true)]
        [Microsoft.Management.Infrastructure.CimSession] $CimSession,
        [Parameter(ParameterSetName="CimSession",Mandatory=$true)]
        [string] $UserID        
        )

    process {
        $ErrorActionPreference = "Stop"

        if ($CimSession) {
            $CimAccount = Get-Account -CimSession $CimSession -UserID $UserID
        }

        if (-not $cimAccount.pstypenames.contains("Microsoft.Management.Infrastructure.CimInstance#CIM_Account")) {
            Write-Error "Only instances of type Microsoft.Management.Infrastructure.CimInstance#CIM_Account may be used"
        }

        Set-AccountState -CimAccount $CimAccount -RequestedState 6
    }
} 

function ConvertTo-OctetString {
    <#
    .Synopsis
        Converts a string to a CIM OctetString
    .Description
        Converts a string to a CIM OctetString.  This should be used where in the MOF, a string property has the OctetString qualifier.

        More details of the OctetString qualifier and definition can be found here:

        http://dmtf.org/sites/default/files/standards/documents/DSP0004_2.7.pdf

    .Parameter String
        String to be converted into an OctetString
    .Parameter Bytes
        Byte array to be converted into an OctetString
    .Example
        PS C:\> $octetstring = ConvertTo-OctetString -String "Secret"
    #>
    
    [CmdletBinding(DefaultParametersetName="String")]
    param (
        [Parameter(ParameterSetName="String",ValueFromPipeLine=$true)]
        [string] $String,
        [Parameter()]
        [byte[]] $Bytes)
    process {
        [string]$octetString = "" # length bytes not needed as this goes over WS-Man
        $ByteArray = $Bytes
        if ($String.Length -gt 0) {
            $encoding = New-Object System.Text.UTF8Encoding
            $ByteArray = $encoding.GetBytes($String)
        }
        $octetString = [System.BitConverter]::ToString($ByteArray) -replace '-',''
        $octetString
    }
}

function Get-MD5Hash ($string) {
    $hasher = [System.Security.Cryptography.MD5]::Create()
    [byte[]]$bytes = [System.Text.Encoding]::UTF8.GetBytes($string)
    ConvertTo-OctetString -Bytes $hasher.ComputeHash($bytes)
    
}

function Convert-Password ([Microsoft.Management.Infrastructure.CimInstance] $Capabilities, [string] $ClearText = "") {
    switch ($Capabilities.SupportedUserPasswordEncryptionAlgorithms) {
        $null { $UserPassword = ConvertTo-OctetString -String $clearText }
        0 { $UserPassword = ConvertTo-OctetString -String $clearText }
        2 { $salt = ""
            if ($Capabilities.UserPasswordEncryptionSalt -ne $null) {
                $salt = $Capabilities.UserPasswordEncryptionSalt
            }
            $UserPassword = Get-MD5Hash -string ($userId + ":" + $salt + ":" + $clearText)
        }
        default {
            $supportedEncryption = @()
            if ($Capabilities.SupportedUserPasswordEncryptionAlgorithms -eq 1) {
                $supportedEncryption = $Capabilities.OtherSupportedUserPasswordEncryptionAlgorithms
            } else {
                $supportedEncryption = "Unknown"
            }
            Write-Error "$($Capatiblities.CimSystemProperties.ServerName) requires a password encryption scheme not supported by this script: $([string]::Join(',',$supportedEncryption))" 
        }
    }
    $UserPassword
}

function New-Account {
    <#
    .Synopsis
        Creates a new account on the target system
    .Description
        Creates a new account on the target system

        More details of the Simple Identity Management Profile can be found here:

        http://dmtf.org/sites/default/files/standards/documents/DSP1034_1.0.pdf

    .Parameter CimSession
        Instance or array of instances of an existing CimSession objects.  See New-CimSession help for details.
    .Parameter UserID
        UserID of the new account
    .Parameter Password
        Password of the new account as a SecureString.  If not specified, you will be prompted.
    .Parameter AccountMgmtService
        Only required if the target system has multiple instances of CIM_AccountManagementService.  See Get-AccountMgmtService for details.
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> New-Account -CimSession $comp1 -UserID Steve
    #>
    
    [CmdletBinding(DefaultParametersetName="CimSession")]
    param (
        [Parameter(ParameterSetName="CimSession")]
        [Microsoft.Management.Infrastructure.CimSession[]] $CimSession = ".",
        [Parameter(Mandatory=$true)]
        [string]$UserID,
        [Parameter(Mandatory=$true)]
        [System.Security.SecureString]$Password,
        [Parameter()]
        [Microsoft.Management.Infrastructure.CimInstance] $AccountMgmtService
        )

    process {
        $ErrorActionPreference = "Stop"

        $returnValueMap = 0,1,2
        $returnValues = "Operation completed successfully","Operation unsupported","Failed"

        $clearText = (New-Object System.Management.Automation.PSCredential('user',$Password)).GetNetworkCredential().Password

        foreach ($system in $CimSession) {
            $simpleIdentityProfile = Get-RegisteredProfile -CimSession $system -RegisteredName "Simple Identity Management" -RegisteredOrganization DMTF
            if ($simpleIdentityProfile -eq $null) {
                Write-Warning "$($system.ComputerName) does not support Simple Identity Management Profile"
                continue
            }

            if ($AccountMgmtService -eq $null) {
                $AcctMgmtServices = Get-AccountMgmtService -CimSession $system
                if ($AcctMgmtServices -eq $null)
                {
                    Write-Error "$($system.ComputerName) did not return CIM_AccountManagementService instance"
                }
                if ($AcctMgmtServices.Count -gt 1) {
                    Write-Error "$($system.ComputerName) contains multiple instances of CIM_AccountManagementService, one must be specified with the AccountMgmtService parameter"
                }
                $AccountMgmtService = $AcctMgmtServices
            } 

            $cap = $AccountMgmtService | Get-CimAssociatedInstance -ResultClassName CIM_AccountManagementCapabilities
            [string]$UserPassword = ""
            # TODO: support case where multiple algoritms are supported
            [int]$EncryptionAlgorithm = $cap.SupportedUserPasswordEncryptionAlgorithms
            $UserPassword = Convert-Password -Capabilities $cap -ClearText $clearText

            $newaccount = New-CimInstance -ClassName CIM_Account -ClientOnly -Property @{SystemCreationClassName="CIM_ComputerSystem";
                SystemName="ManagedSystem";CreationClassName="CIM_Account";
                Name=$UserID;UserID=$UserID;UserPassword=$UserPassword;
                UserPasswordEncryptionAlgorithm=$EncryptionAlgorithm} -Namespace $AccountMgmtService.CimSystemProperties.Namespace

            $cs = $AccountMgmtService | Get-CimAssociatedInstance -ResultClassName CIM_ComputerSystem

            $out = Invoke-CimMethod -InputObject $AccountMgmtService -MethodName CreateAccount -Arguments @{System=[ref]$cs;AccountTemplate=$newaccount}
            if ($out.ReturnValue -eq 0) {
                $out.Account | Get-CimInstance | Get-Account
            } else {
                Write-Error "$($system.ComputerName) returned $(Get-ValueFromMap $returnValues $returnValueMap $out.ReturnValue)"
            }
        }        
    }
}

function Set-Account {
    <#
    .Synopsis
        Set account properties on the target system
    .Description
        Set account properties.  Currently, only updating the password is supported.

        More details of the Simple Identity Management Profile can be found here:

        http://dmtf.org/sites/default/files/standards/documents/DSP1034_1.0.pdf

    .Parameter CimAccount
        Instance of an existing CIM_Account object.  See Get-Account help for details.
    .Parameter Password
        New password as a SecureString.  If not specified, you will be prompted.
    .Parameter CimSession
        Instance of an existing CimSession object.  See New-CimSession help for details.
    .Parameter UserID
        UserID of the specific account.
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> Get-Account -CimSession $comp1 -UserId Administrator | Disable-Account
    #>
    
    [CmdletBinding(DefaultParametersetName="CimSession")]
    param (
        [Parameter(ParameterSetName="CimAccount",ValueFromPipeLine=$true)]
        [Microsoft.Management.Infrastructure.CimInstance] $CimAccount,
        [Parameter(Mandatory=$true)]
        [System.Security.SecureString]$Password,
        [Parameter(ParameterSetName="CimSession",Mandatory=$true)]
        [Microsoft.Management.Infrastructure.CimSession] $CimSession,
        [Parameter(ParameterSetName="CimSession",Mandatory=$true)]
        [string] $UserID        
        )

    process {
        $ErrorActionPreference = "Stop"
        if (-not $cimAccount.pstypenames.contains("Microsoft.Management.Infrastructure.CimInstance#CIM_Account")) {
            Write-Error "Only instances of type Microsoft.Management.Infrastructure.CimInstance#CIM_Account may be used"
        }

        if ($Password.Length -gt 0) {
            $clearText = (New-Object System.Management.Automation.PSCredential('user',$Password)).GetNetworkCredential().Password

            if ($CimSession) {
                $CimAccount = Get-CIMAccount -CimSession $CimSession -UserID $UserID
            }

            # TODO: handle case where account has multiple identities
            $cap = $CimAccount | Get-CimAssociatedInstance -ResultClassName CIM_Identity | Get-CimAssociatedInstance -ResultClassName CIM_AccountManagementService | Get-CimAssociatedInstance -ResultClassName CIM_AccountManagementCapabilities

            $UserPassword = Convert-Password -Capabilities $cap -ClearText $clearText
            $CimAccount.UserPassword = $UserPassword
            $CimAccount | Set-CimInstance
            Write-Verbose "Command completed successfully."
        } else {
            Write-Error "Empty password specified"
        }
    }
}

function Remove-Account {
    <#
    .Synopsis
        Remove account from the target system
    .Description
        Remove account from the target system

        More details of the Simple Identity Management Profile can be found here:

        http://dmtf.org/sites/default/files/standards/documents/DSP1034_1.0.pdf

    .Parameter CimAccount
        Instance of an existing CIM_Account object.  See Get-Account help for details.
    .Parameter CimSession
        Instance of an existing CimSession object.  See New-CimSession help for details.
    .Parameter UserID
        UserID of the specific account.
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> Get-Account -CimSession $comp1 -UserId Steve | Remove-Account
    #>
    
    [CmdletBinding(DefaultParametersetName="CimSession",SupportsShouldProcess=$true)]
    param (
        [Parameter(ParameterSetName="CimAccount",ValueFromPipeLine=$true,Mandatory=$true)]
        [Microsoft.Management.Infrastructure.CimInstance] $CimAccount,
        [Parameter(ParameterSetName="CimSession",Mandatory=$true)]
        [Microsoft.Management.Infrastructure.CimSession] $CimSession,
        [Parameter(ParameterSetName="CimSession",Mandatory=$true)]
        [string] $UserID        
        )

    process {
        $ErrorActionPreference = "Stop"

        if ($CimSession) {
            $CimAccount = Get-CIMAccount -CimSession $CimSession -UserID $UserID
        }

        if (-not $cimAccount.pstypenames.contains("Microsoft.Management.Infrastructure.CimInstance#CIM_Account")) {
            Write-Error "Only instances of type Microsoft.Management.Infrastructure.CimInstance#CIM_Account may be used"
        }

        if ($PSCmdlet.ShouldProcess($CimAccount.GetCimSessionComputerName(),"ClearLog")) {
            if ($Force -or $PSCmdlet.ShouldContinue("","")) {
                Remove-CimInstance -InputObject $CimAccount
            }
        }
    }
}

function Set-Role {
    <#
    .Synopsis
        Add authorized roles to an account on the target system
    .Description
        Add authorized roles to an account on the target system

        More details of the Role Based Authorization Profile can be found here:

        http://dmtf.org/sites/default/files/standards/documents/DSP1039_1.0.pdf

    .Parameter CimAccount
        Instance of an existing CIM_Account object.  See Get-Account help for details.
    .Parameter Role
        Array of CIM_Role instances.  Set Get-Role help for details.
    .Parameter CimSession
        Instance of an existing CimSession object.  See New-CimSession help for details.
    .Parameter UserID
        UserID of the specific account.
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> $roles = Get-Role -CimSession $comp1 -CommonName CIM:Administrator,CIM:Operator
        PS C:\> Get-Role -CimSession $comp1 | Set-Role -Role $roles
    #>
    [CmdletBinding(DefaultParametersetName="CimSession")]
    param (
        [Parameter(ParameterSetName="CimAccount",Mandatory=$true,ValueFromPipeLine=$true)]
        [Microsoft.Management.Infrastructure.CimInstance] $CimAccount,
        [Parameter(Mandatory=$true)]
        [Microsoft.Management.Infrastructure.CimInstance[]] $Role,
        [Parameter(ParameterSetName="CimSession",Mandatory=$true)]
        [Microsoft.Management.Infrastructure.CimSession] $CimSession,
        [Parameter(ParameterSetName="CimSession",Mandatory=$true)]
        [string] $UserID        
        )

    process {
        $ErrorActionPreference = "Stop"
        $returnValueMap = 0,1,2
        $returnValues = "Operation completed successfully","Operation unsupported","Failed"

        if ($CimSession) {
            $CimAccount = Get-CIMAccount -CimSession $CimSession -UserID $UserID
        }

        if (-not $cimAccount.pstypenames.contains("Microsoft.Management.Infrastructure.CimInstance#CIM_Account")) {
            Write-Error "Only instances of type Microsoft.Management.Infrastructure.CimInstance#CIM_Account may be used"
        }
        $roles = @()
        $Role | ForEach-Object {
            if (-not $_.pstypenames.contains("Microsoft.Management.Infrastructure.CimInstance#CIM_Role")) {
                Write-Error "Only instances of type Microsoft.Management.Infrastructure.CimInstance#CIM_Role may be used"
            }
            $roles += [ref]$_
        }

        $system = Get-CimSession -InstanceId $CimAccount.GetCimSessionInstanceId()
        $rbap = Get-RegisteredProfile -CimSession $system -RegisteredName "Role Based Authorization" -RegisteredOrganization DMTF
        if ($rbap -eq $null) {
            Write-Warning "$($system.ComputerName) does not support Role Based Authorization Profile"
            continue
        }

        $roleSvc = $rbap | Get-CentralInstance -ResultClassName CIM_RoleBasedAuthorizationService
        if ($roleSvc -eq $null)
        {
            Write-Warning "The remote endpoint did not return CIM_RoleBasedAuthorizationService"
            return
        }

        $identity = $CimAccount | Get-CimAssociatedInstance -ResultClassName CIM_Identity
        if ($identity.Count -gt 1) { #TODO: handle case where there's multiple identities for an account
            Write-Error "Module does not currently support setting role where account has multiple identities"
        }
        
        $cap = $roleSvc | Get-CimAssociatedInstance -ResultClassName CIM_RoleBasedManagementCapabilities
        if ($cap.SupportedMethods -contains 6) { # supports AssignRoles
            $out = Invoke-CimMethod -InputObject $roleSvc -MethodName AssignRoles -Arguments @{Identity=[ref]$identity;Roles=$roles}
            if ($out.ReturnValue -eq 0) {
                Write-Verbose "$(Get-ValueFromMap $returnValues $returnValueMap $out.ReturnValue)"
            } else {
                Write-Error "$($system.ComputerName) returned $(Get-ValueFromMap $returnValues $returnValueMap $out.ReturnValue)"
            }
        } else { # on systems that don't support AssignRoles, we'll try to assign the same privileges as the specified role
            # DSP1039 refers to this as one-to-one correspondence
            Write-Warning "$($system.ComputerName) does not support AssignRoles; assigning privileges instead"
            $privs = $role | Get-CimAssociatedInstance -ResultClassName CIM_Privilege
            foreach ($priv in $privs) {
                $activityQualifiers = $priv.ActivityQualifiers
                $activities = $priv.Activities
                $qualifierFormats = $priv.QualifierFormats
                $userRole = $identity | Get-CimAssociatedInstance -ResultClassName CIM_Role
                if ($userRole.Count -gt 1) {
                    Write-Error "Module does not currently support setting privileges where account has multiple roles and AssignRoles() method is not implemented on target"
                }
                $userPrivilege = $userRole | Get-CimAssociatedInstance -ResultClassName CIM_Privilege
                if ($userPrivilege.Count -gt 1) {
                    Write-Error "Module does not currently support assign privileges where account role has multiple privilege instances"
                }
                $userPrivilege.ActivityQualifiers = $activityQualifiers
                $userPrivilege.Activities = $activities
                $userPrivilege.QualifierFormats = $qualifierFormats
                $userPrivilege | Set-CimInstance                
            }
        }
        Write-Verbose "Successfully set role for user $($CimAccount.UserID)"
    }
}

function Get-Role {
    <#
    .Synopsis
        Retrieve the roles from the target system
    .Description
        Retrieve the roles from the target system

        More details of the Role Based Authorization Profile can be found here:

        http://dmtf.org/sites/default/files/standards/documents/DSP1039_1.0.pdf

    .Parameter CimSession
        Instance or array of instances of an existing CimSession objects.  See New-CimSession help for details.
    .Parameter CommonName
        CommonName value of a role to filter against
    .Example
        PS C:\> # Create new CimSession to out-of-band DASH capable hardware using HTTP and Digest
        PS C:\> $comp1 = New-CimSession -ComputerName comp1 -Authentication Digest -Credential $cred -port 623
        PS C:\> Get-Role -CimSession $comp1 

        CommonName         ElementName        Privileges                                                                                                PSComputerName
        ----------         -----------        ----------                                                                                                --------------
        CIM:Administrator  Administrator Role {Base Desktop and Mobile Read Privilege, Base Desktop and Mobile Write Privilege, Base Desktop and Mob... comp1
        CIM:Operator       Operator Role      {Base Desktop and Mobile Read Privilege, Base Desktop and Mobile Execute Privilege, Physical Asset Rea... comp1
        CIM:ReadOnly       Read Only Role     {Base Desktop and Mobile Read Privilege, Physical Asset Read Privilege, CPU Read Privilege, System Mem... comp1
        CIM:Auditor        Auditor Role       {Record Log Read Privilege, Record Log Audit Privilege}                                                   comp1
    #>
    [CmdletBinding(DefaultParametersetName="CimSession")]
    param (
        [Parameter(ParameterSetName="CimSession")]
        [Microsoft.Management.Infrastructure.CimSession[]] $CimSession = ".",
        [string[]] $CommonName)

    process {
        $ErrorActionPreference = "Stop"

        foreach ($system in $CimSession) {
            $rbap = Get-RegisteredProfile -CimSession $system -RegisteredName "Role Based Authorization" -RegisteredOrganization DMTF
            if ($rbap -eq $null) {
                Write-Warning "$($system.ComputerName) does not support Role Based Authorization Profile"
                continue
            }

            $roleSvc = $rbap | Get-CentralInstance -ResultClassName CIM_RoleBasedAuthorizationService
            if ($roleSvc -eq $null)
            {
                Write-Warning "The remote endpoint did not return CIM_RoleBasedAuthorizationService"
                return
            }

            foreach ($role in $roleSvc | Get-CimAssociatedInstance -ResultClassName CIM_Role -Association CIM_ServiceAffectsElement) {
                
                if ($CommonName.Length -gt 0 -and $CommonName -inotcontains $role.CommonName ) {
                    continue
                }

                $priv = $role | Get-CimAssociatedInstance -ResultClassName CIM_Privilege
                $privs  = @()
                if ($priv -ne $null -and $priv.PrivilegeGranted -eq $true) {
                    if ($priv.ElementName.Length -ne 0) { 
                        $privs += $priv.ElementName
                    } else {
                        $privs += $priv.InstanceID
                    }
                }
                $role | Add-Member -MemberType NoteProperty -Name Privileges -Value $privs
                $role.pstypenames.insert(0,"Microsoft.Management.Infrastructure.CimInstance#CIM_Role")
                $role
            }
        }
    }
}

function ConvertFrom-HexString 
{ 
    param($HexString)
    $HexString -split "(..)" | ? { $_ } | % { [Convert]::ToByte($_, 16) } 
}

function ConvertTo-IPMI
{
    param(
        [byte] $sequenceId = 0,
        [byte] $messageType,
        [byte] $messageTag = 0,
        [byte[]] $data)

    [byte]$version = 0x06 # ASF
    [byte]$reserved = 0x00
    [byte]$class = 0x06 # ASF
    [byte[]]$IANA = 0x00,0x00,0x11,0xBE # ASF
    [byte[]]$RMCPHeader = $version, $reserved, $sequenceId

    [byte[]] $bytes = $RMCPHeader
    $bytes += $class
    $bytes += $IANA
    $bytes += $messageType
    $bytes += $messageTag
    $bytes += $reserved
    $bytes += $data.Length

    if ($data.Length -gt 0) {
        $bytes += $data
    }

    $bytes
}

function Pop-ByteString {
    param ([ref][string] $byteString, [int] $bytes, [switch] $RemoveDash)

    $pop = $byteString.Value.SubString(0,3*$bytes)
    if ($RemoveDash) {
        $pop = $pop.Replace("-","")
    }
    $byteString.Value = $byteString.Value.Remove(0,3*$bytes)
    $pop
}

function ConvertFrom-ByteString {
    param ([string]$byteString)
    [Convert]::ToInt32($byteString.Replace("-",""),16)
}

function ConvertFrom-RMCP {
    param ($byteString)

    $RMCPAck = "06-00-00-86"
    $RMCPHeader = "06-00-([0-9A-F]{2})-06-00-00-(11-BE|01-57)-" # handle both ASF and Intel cases in the header

    if ($byteString -eq $RMCPAck) {
        Write-Verbose "RMCP Ack received"
        return
    }

    if ($byteString -match $RMCPHeader) {
        $null = Pop-ByteString ([ref]$byteString) 8

        $messageType = Pop-ByteString ([ref]$byteString) 1
        switch ($messageType.Replace("-","")) {
            "40" {
                Write-Verbose "RMCP Presence Pong Response"
                $pong = New-Object -TypeName System.Management.Automation.PSObject -Property @{
                    IPMI=$false;Security=$false;ASF=$false;IANA="Unknown";DASH=$false;HTTP="Unknown";
                    HTTPS="Unknown"}
                $pong.PSTypeNames.Insert(0,"RMCP.PresencePong")

                $messageTag = Pop-ByteString ([ref]$byteString) 1
                $reserved = Pop-ByteString ([ref]$byteString) 1
                $dataLength = Pop-ByteString ([ref]$byteString) 1
                $IANA = Pop-ByteString ([ref]$byteString) 4
                switch ($IANA.Replace("-","")) {
                    "000011BE" { 
                        $pong.IANA = "ASF"
                        $oemDefined = Pop-ByteString ([ref]$byteString) 4
                    }
                    "00000157" { 
                        $pong.IANA = "Intel"
                        $oemDefined = Pop-ByteString ([ref]$byteString) 4
                    }
                    "0000113D" { 
                        $pong.IANA = "Broadcom"
                        $HTTP = Pop-ByteString ([ref]$byteString) 2
                        $pong.HTTP = ConvertFrom-ByteString $HTTP
                        $HTTPS = Pop-ByteString ([ref]$byteString) 2
                        $pong.HTTPS = ConvertFrom-ByteString $HTTPS
                    }
                    Default { 
                        Write-Verbose "Unknown IANA: $IANA" 
                        $oemDefined = Pop-ByteString ([ref]$byteString) 4
                    }
                }
                [byte]$supportedEntities = [System.Convert]::ToByte((Pop-ByteString ([ref]$byteString) 1 -RemoveDash),16)
                if ($supportedEntities -band 0x80) {
                    $pong.IPMI = $true
                }
                if ($supportedEntities -band 0x01) {
                    $pong.ASF = $true
                }
                [byte]$supportedInteractions = [System.Convert]::ToByte((Pop-ByteString ([ref]$byteString) 1 -RemoveDash),16)
                if ($supportedInteractions -band 0x80) {
                    $pong.Security = $true
                }
                if ($supportedInteractions -band 0x20) {
                    $pong.DASH = $true
                    if ($pong.HTTP -eq "Unknown") {
                        $pong.HTTP = 623
                    }
                    if ($pong.HTTPS -eq "Unknown") {
                        $pong.HTTPS = 664
                    }
                }
                $pong
            }
            "41" {
                Write-Verbose "RMCP Capabilities Response"
            }
            "42" {
                Write-Verbose "RMCP System State Response"
            }
            "43" {
                Write-Verbose "RMCP Open Session Response"
            }
            "44" {
                Write-Verbose "RMCP Close Session Response"
            }
            default {
                Write-Warning "Unknown message type: $messagetype"
            }            
        }
    } else {
        Write-Warning "Unknown response: $byteString"
    }
}

function Send-RMCPping {
    param ([IPAddress] $targetIP,
        [switch] $ResolveNames = $false)
    $RMCPport = 623

    $bytes = ConvertTo-IPMI -messageType 0x80 -messageTag 0x33
    $endPoint = New-Object System.Net.IPEndPoint $targetIP,$RMCPport
    $udpClient = New-Object System.Net.Sockets.UdpClient
    $udpClient.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IP,[System.Net.Sockets.SocketOptionName]::PacketInformation,$true)

    $null = $udpClient.Send($bytes, $bytes.Length, $endPoint)  # method returns number of bytes sent

    $localEndPoint = New-Object System.Net.IPEndPoint ([IPAddress]::Any),0
    Start-Sleep -Milliseconds 200 # give managed node time to formulate response

    while ($udpClient.Available -gt 0) {
        try {
            [byte[]] $receiveBytes = $udpClient.Receive([ref]$localEndPoint)
            $byteString = [System.BitConverter]::ToString($receiveBytes)
            Write-Verbose "Bytes Received: $bytestring"
            $pong = ConvertFrom-RMCP $byteString
            if ($ResolveNames) {
                try {  # exception if reverse lookup fails because computer is not registered with DNS
                    $computerName = [System.Net.Dns]::GetHostByAddress($localEndPoint.Address)
                } catch {
                    $computerName = $null
                }
            }
            if ($computerName) {
                $pong | Add-Member -MemberType NoteProperty -Name ComputerName -Value $computerName.HostName
            }
            $pong | Add-Member -MemberType NoteProperty -Name RemoteAddress -Value $localEndPoint.Address.ToString()
            $pong
        } catch [System.Net.Sockets.SocketException] {
            Write-Warning "$targetIP : $($_.Exception.Message)"
        }
    }

    $udpClient.Close()
}

function Test-RMCPConnection {
    <#
    .Synopsis
        Perform RMCP Ping
    .Description
        Send RMCP Ping request to target
        
        More information about the data block for RMCP Ping available here: http://www.dmtf.org/sites/default/files/standards/documents/DSP0136.pdf
        More information on relation of RMCP Ping to DASH available here: http://dmtf.org/sites/default/files/standards/documents/DSP0232_1.1.0.pdf

    .Parameter CimSession
        Instance or array of instances of an existing CimSession objects.  See New-CimSession help for details.

        The CimSession is only used to get the target computer name.
    .Parameter TargetHost
        Computer name to send the RMCP Ping
    .Parameter IPAddress
        IPAddress object to send the RMCP Ping
    .Parameter Broadcast
        Send RMCP Ping as broadcast on local subnet
    .Parameter ResolveNames
        Use DNS to resolve IP Addresses to Computer Names
    .Example
        PS C:\> Test-RMCPConnection -Broadcast
        IANA             DASH  HTTP    HTTPS   IPMI  Security     RemoteAddress  ComputerName
        ----             ----  ----    -----   ----  -----------  -------------  ------------
        Contoso          True  623     664     True  False        192.168.0.2    comp1
    #>
    [CmdletBinding(DefaultParametersetName="TargetHost")]
    param (
        [Parameter(ParameterSetName="CimSession")]
        [Microsoft.Management.Infrastructure.CimSession[]] $CimSession = ".",
        [Parameter(ParameterSetName="TargetHost")]
        [string] $TargetHost,
        [Parameter(ParameterSetName="IPAddress")]
        [IPAddress] $IPAddress,
        [Parameter(ParameterSetName="Broadcast")]
        [switch] $Broadcast = $false,
        [switch] $ResolveNames = $false)

    process {
        $ErrorActionPreference = "Stop"

        $params = @{}
        if ($ResolveNames) {
            $params.Add("ResolveNames", $true)
        }

        if ($Broadcast) {
            $ipConfiguration = Get-WmiObject Win32_NetworkAdapterConfiguration | 
                Where-Object IPAddress | Select -First 1 
            $ipAddress = @($ipConfiguration.IPAddress)[0] 
            $subnetMask = @($ipConfiguration.IPSubnet)[0]

            [UInt32]$ip = [IPAddress]::Parse($IPAddress).Address 
            [UInt32]$subnet = [IPAddress]::Parse($SubnetMask).Address 
            [UInt32]$broadcast = $ip -band $subnet

            $BroadcastAddress = New-Object IPAddress ($broadcast -bor -bnot $subnet)

            Send-RMCPping -target $BroadcastAddress @params
        } elseif ($TargetHost) {
            $targetIp = [IPAddress]::Parse([System.Net.Dns]::GetHostByName($TargetHost).AddressList[0])
            Send-RMCPping -targetIP $targetIp @params
        } elseif ($IPAddress) {
            Send-RMCPping -targetIP $IPAddress @params
        } else {
            foreach ($system in $CimSession) {
                $target = $system.ComputerName
                $targetIp = [IPAddress]::Parse([System.Net.Dns]::GetHostByName($target).AddressList[0])

                $pong = Send-RMCPping -target $targetIp @params
                $pong
            }
        }
    }
}


#endregion