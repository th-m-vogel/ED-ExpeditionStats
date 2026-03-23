#############################################################################
####              Sevetamryn & Claude 2026                               ####
#############################################################################
# THIS SOFTWARE IS PROVIDED "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
# INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY
# AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
# OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
# WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
# OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
# EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#############################################################################
#
# Command line options:
#   (none)        Run with default expedition (DW3: 2026-01-18 to now)
#   -StartDate    Expedition start date. Accepts real-world (2026-01-18)
#                 or in-game (3312-01-18) format.
#   -EndDate      Expedition end date (optional, defaults to today).
#                 Accepts same formats as -StartDate.
#   -Commander    Filter output to a single commander name (optional).
#                 If omitted, all commanders found are reported separately.
#   -LogPath      Path to Elite Dangerous journal folder (optional).
#
#############################################################################
param(
    [string]$StartDate  = "2026-01-18",
    [string]$EndDate    = "",
    [string]$Commander  = "",
    [string]$LogPath    = ""
)

if (-not $LogPath) {
    $homePath = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
    $LogPath = Join-Path $homePath "Saved Games\Frontier Developments\Elite Dangerous"
}
$FilePattern = "Journal*.log"

###
# Date parsing — accept real-world or in-game (offset 1286 years)
###
Function Convert-ToRealDate {
    param([string]$DateStr)
    if ($DateStr -match "^(\d{4})-(\d{2})-(\d{2})$") {
        $year = [int]$Matches[1]
        if ($year -gt 3000) { $year -= 1286 }
        return [datetime]::new($year, [int]$Matches[2], [int]$Matches[3])
    }
    throw "Invalid date format: $DateStr. Use YYYY-MM-DD."
}

$startDT = Convert-ToRealDate -DateStr $StartDate
$endDT   = if ($EndDate) { (Convert-ToRealDate -DateStr $EndDate).AddDays(1) } else { (Get-Date).AddDays(1) }

###
# Per-commander stats factory
###
Function New-CommanderStats {
    return @{
        # Distance
        FsdDistance        = 0.0
        FsdJumps           = 0
        FsdSupercharged    = 0
        CarrierDistance    = 0.0
        # Carrier tracking state (per-commander)
        LastStarPos        = $null
        LastOnCarrier      = $false
        LastSystem         = ""
        PendingCarrierCheck = $false
        # Payouts
        PayoutCartographic = 0.0
        PayoutGenetic      = 0.0
        PayoutCodex        = 0.0
        GeneticScans       = 0
        GeneticSpecies     = [System.Collections.Generic.HashSet[string]]::new()
        # Exploration
        SystemsVisited     = [System.Collections.Generic.HashSet[string]]::new()
        SystemsDiscovered  = [System.Collections.Generic.HashSet[string]]::new()
        CodexEntries       = [System.Collections.Generic.HashSet[string]]::new()
        # Incidents
        Deaths             = 0
        # First discoveries
        EarthLike          = [System.Collections.Generic.HashSet[string]]::new()
        WaterWorld         = [System.Collections.Generic.HashSet[string]]::new()
        AmmoniaWorld       = [System.Collections.Generic.HashSet[string]]::new()
        Terraformable      = [System.Collections.Generic.HashSet[string]]::new()
        NeutronStar        = [System.Collections.Generic.HashSet[string]]::new()
        WhiteDwarf         = [System.Collections.Generic.HashSet[string]]::new()
        BlackHole          = [System.Collections.Generic.HashSet[string]]::new()
        WolfRayet          = [System.Collections.Generic.HashSet[string]]::new()
    }
}

###
# Distance calculation
###
Function Get-Distance {
    param($pos1, $pos2)
    $dx = $pos2[0] - $pos1[0]
    $dy = $pos2[1] - $pos1[1]
    $dz = $pos2[2] - $pos1[2]
    return [math]::Sqrt($dx*$dx + $dy*$dy + $dz*$dz)
}

###
# Journal file filtering by filename date
###
Function Get-JournalFileDate {
    param([string]$FileName)
    # Format 1: Journal.YYYY-MM-DDTHHMMSS.01.log
    if ($FileName -match "Journal\.(\d{4}-\d{2}-\d{2})T") {
        return [datetime]::ParseExact($Matches[1], "yyyy-MM-dd", $null)
    }
    # Format 2: Journal.YYMMDDHHMMSS.01.log
    if ($FileName -match "Journal\.(\d{2})(\d{2})(\d{2})\d+\.") {
        return [datetime]::new(2000 + [int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
    }
    return $null
}

Function Get-JournalFiles {
    Get-ChildItem -Path $LogPath -Filter $FilePattern |
        Where-Object {
            $fileDate = Get-JournalFileDate -FileName $_.Name
            $fileDate -and $fileDate -ge $startDT.Date -and $fileDate -lt $endDT.Date
        } |
        Sort-Object Name
}

###
# Read commander name from journal file header
###
Function Get-FileCommander {
    param($FilePath)
    $reader = [System.IO.File]::OpenText($FilePath)
    $name = $null
    $linesRead = 0
    while (($read = $reader.ReadLine()) -ne $null -and $linesRead -lt 20) {
        $linesRead++
        try {
            $obj = $read | ConvertFrom-Json
            if ($obj.event -eq "Commander" -and $obj.Name) {
                $name = $obj.Name
                break
            }
        } catch {}
    }
    $reader.Close()
    return $name
}

###
# Event processing — operates on a passed-in stats object
###
Function Invoke-StatEvent {
    param($line, $s)

    ### Offline carrier distance: login after carrier jumped
    if ($line.event -eq "LoadGame") {
        $s.PendingCarrierCheck = $true
    }

    if ($line.event -eq "Location" -and $s.PendingCarrierCheck) {
        $s.PendingCarrierCheck = $false
        if ($s.LastStarPos -and $s.LastOnCarrier -and $line.StarSystem -ne $s.LastSystem) {
            if ($line.StarPos) {
                $s.CarrierDistance += Get-Distance -pos1 $s.LastStarPos -pos2 $line.StarPos
            }
        }
        if ($line.StarPos) {
            $s.LastStarPos   = $line.StarPos
            $s.LastSystem    = $line.StarSystem
            $s.LastOnCarrier = ($line.StationType -eq "FleetCarrier")
        }
    }

    ### Track last known position and carrier status before logout
    if ($line.event -eq "Location" -and $line.StarPos) {
        $s.LastStarPos   = $line.StarPos
        $s.LastSystem    = $line.StarSystem
        $s.LastOnCarrier = ($line.StationType -eq "FleetCarrier")
    }

    ### Online carrier jump
    if ($line.event -eq "CarrierJump" -and $line.StarPos) {
        if ($s.LastStarPos) {
            $s.CarrierDistance += Get-Distance -pos1 $s.LastStarPos -pos2 $line.StarPos
        }
        $s.LastStarPos   = $line.StarPos
        $s.LastSystem    = $line.StarSystem
        $s.LastOnCarrier = $true
    }

    ### FSD jumps
    if ($line.event -eq "FSDJump") {
        $s.FsdJumps++
        $s.FsdDistance += $line.JumpDist
        $s.SystemsVisited.Add($line.StarSystem) | Out-Null
    }

    ### Supercharged jump (neutron/white dwarf cone boost)
    if ($line.event -eq "JetConeBoost") {
        $s.FsdSupercharged++
    }

    ### Payouts
    if ($line.event -eq "MultiSellExplorationData") {
        $s.PayoutCartographic += $line.TotalEarnings
    }

    if ($line.event -eq "SellOrganicData") {
        foreach ($entry in $line.BioData) {
            $s.PayoutGenetic += $entry.Value + $entry.Bonus
        }
    }

    if ($line.event -eq "ScanOrganic" -and $line.ScanType -eq "Analyse") {
        $s.GeneticScans++
        $s.GeneticSpecies.Add($line.Species) | Out-Null
    }

    if ($line.event -eq "RedeemVoucher" -and $line.Type -eq "codex") {
        $s.PayoutCodex += $line.Amount
    }

    ### Deaths
    if ($line.event -eq "Died") {
        $s.Deaths++
    }

    ### Codex entries — unique EntryID+Region combinations, new entries only
    if ($line.event -eq "CodexEntry" -and $line.IsNewEntry -eq $true) {
        $s.CodexEntries.Add("$($line.EntryID)_$($line.Region)") | Out-Null
    }

    ### First discoveries via Scan
    if ($line.event -eq "Scan" -and $line.WasDiscovered -eq $false) {

        if ($line.StarType) {
            $s.SystemsDiscovered.Add($line.StarSystem) | Out-Null
        }

        $bodyKey = $line.BodyName

        switch ($line.PlanetClass) {
            "Earthlike body"  { $s.EarthLike.Add($bodyKey)    | Out-Null }
            "Water world"     { $s.WaterWorld.Add($bodyKey)   | Out-Null }
            "Ammonia world"   { $s.AmmoniaWorld.Add($bodyKey) | Out-Null }
        }
        if ($line.TerraformState -eq "Terraformable") { $s.Terraformable.Add($bodyKey) | Out-Null }

        if ($line.StarType) {
            if ($line.StarType -eq "N")                { $s.NeutronStar.Add($bodyKey) | Out-Null }
            elseif ($line.StarType -eq "BH")           { $s.BlackHole.Add($bodyKey)   | Out-Null }
            elseif ($line.StarType -match "^D")        { $s.WhiteDwarf.Add($bodyKey)  | Out-Null }
            elseif ($line.StarType -match "^W")        { $s.WolfRayet.Add($bodyKey)   | Out-Null }
        }
    }
}

###
# Print report for one commander
###
Function Write-CommanderReport {
    param([string]$Name, $s)

    $totalDistance = $s.FsdDistance + $s.CarrierDistance
    $totalPayout   = $s.PayoutCartographic + $s.PayoutGenetic + $s.PayoutCodex
    $endLabel      = if ($EndDate) { $EndDate } else { "now" }

    Write-Host ""
    Write-Host "=================================================="
    Write-Host "  Expedition Statistics — $Name"
    Write-Host "  Period: $StartDate to $endLabel"
    Write-Host "=================================================="
    Write-Host ""
    Write-Host "PAYOUTS"
    Write-Host ("  Cartographic:     {0:N0} cr" -f $s.PayoutCartographic)
    Write-Host ("  Genetic:          {0:N0} cr" -f $s.PayoutGenetic)
    Write-Host ("  Genetic scans:    {0}  ({1} unique species)" -f $s.GeneticScans, $s.GeneticSpecies.Count)
    Write-Host ("  Codex:            {0:N0} cr" -f $s.PayoutCodex)
    Write-Host ("  Total:            {0:N0} cr" -f $totalPayout)
    Write-Host ""
    Write-Host "EXPLORATION"
    Write-Host ("  Systems visited:   {0}" -f $s.SystemsVisited.Count)
    Write-Host ("  Systems discovered:{0}" -f $s.SystemsDiscovered.Count)
    Write-Host ("  Codex entries:     {0}" -f $s.CodexEntries.Count)
    Write-Host ""
    Write-Host "FSD JUMPS"
    Write-Host ("  Total jumps:       {0}" -f $s.FsdJumps)
    Write-Host ("  Supercharged:      {0}" -f $s.FsdSupercharged)
    Write-Host ""
    Write-Host "DISTANCE TRAVELED"
    Write-Host ("  FSD:               {0:N1} ly" -f $s.FsdDistance)
    Write-Host ("  Carrier:           {0:N1} ly" -f $s.CarrierDistance)
    Write-Host ("  Total:             {0:N1} ly" -f $totalDistance)
    Write-Host ""
    Write-Host "FIRST DISCOVERIES"
    Write-Host ("  Earth-like worlds: {0}" -f $s.EarthLike.Count)
    Write-Host ("  Water worlds:      {0}" -f $s.WaterWorld.Count)
    Write-Host ("  Ammonia worlds:    {0}" -f $s.AmmoniaWorld.Count)
    Write-Host ("  Terraformable:     {0}" -f $s.Terraformable.Count)
    Write-Host ("  Neutron stars:     {0}" -f $s.NeutronStar.Count)
    Write-Host ("  White dwarfs:      {0}" -f $s.WhiteDwarf.Count)
    Write-Host ("  Black holes:       {0}" -f $s.BlackHole.Count)
    Write-Host ("  Wolf-Rayet stars:  {0}" -f $s.WolfRayet.Count)
    Write-Host ""
    if ($s.Deaths -gt 0) {
        Write-Host ("  Note: {0} death(s) recorded. Distance figures may include recovery travel." -f $s.Deaths)
        Write-Host ""
    }
    Write-Host "=================================================="
}

###
# Main — process journals
###
$files = Get-JournalFiles
if ($files.Count -eq 0) {
    Write-Host "No journal files found for the specified date range."
    exit
}

# Per-commander stats dictionary
$commanderStats = @{}

$fileCount = $files.Count
$fileIndex = 0
foreach ($file in $files) {
    $fileIndex++
    $pct = [int]($fileIndex / $fileCount * 100)
    Write-Progress -Activity "Processing journals" -Status "$fileIndex / $fileCount  $($file.Name)" -PercentComplete $pct

    $fileCommander = Get-FileCommander -FilePath $file.FullName

    # Skip files with no commander (empty/crash sessions)
    if (-not $fileCommander) { continue }

    # Apply -Commander filter if specified
    if ($Commander -and $fileCommander -ne $Commander) { continue }

    # Get or create stats bucket for this commander
    if (-not $commanderStats.ContainsKey($fileCommander)) {
        $commanderStats[$fileCommander] = New-CommanderStats
    }
    $s = $commanderStats[$fileCommander]

    $reader = [System.IO.File]::OpenText($file.FullName)
    while (($read = $reader.ReadLine()) -ne $null) {
        try {
            $line = $read | ConvertFrom-Json
            if ($line.timestamp) {
                $ts = [datetime]$line.timestamp
                if ($ts -ge $startDT -and $ts -lt $endDT) {
                    Invoke-StatEvent -line $line -s $s
                }
            }
        } catch {}
    }
    $reader.Close()
}
Write-Progress -Activity "Processing journals" -Completed

if ($commanderStats.Count -eq 0) {
    Write-Host "No data found for the specified parameters."
    exit
}

# Print one report per commander (sorted by name)
foreach ($name in ($commanderStats.Keys | Sort-Object)) {
    Write-CommanderReport -Name $name -s $commanderStats[$name]
}
