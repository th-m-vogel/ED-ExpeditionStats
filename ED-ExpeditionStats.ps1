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
#   -LogPath      Path to Elite Dangerous journal folder (optional).
#
#############################################################################
param(
    [string]$StartDate = "2026-01-18",
    [string]$EndDate   = "",
    [string]$LogPath   = ""
)

if (-not $LogPath) {
    $home = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME }
    $LogPath = Join-Path $home "Saved Games\Frontier Developments\Elite Dangerous"
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
# Statistics accumulators
###
$stats = @{
    FsdDistance        = 0.0
    FsdJumps           = 0
    FsdSupercharged    = 0
    CarrierDistance    = 0.0
    Deaths             = 0
    SystemsVisited     = [System.Collections.Generic.HashSet[string]]::new()
    SystemsDiscovered  = [System.Collections.Generic.HashSet[string]]::new()
    CodexEntries       = 0
    EarthLike          = 0
    WaterWorld         = 0
    AmmoniaWorld       = 0
    Terraformable      = 0
    NeutronStar        = 0
    WhiteDwarf         = 0
    BlackHole          = 0
    WolfRayet          = 0
}

# For offline carrier distance tracking
$lastStarPos       = $null
$lastOnCarrier     = $false
$lastSystem        = ""

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
Function Get-JournalFiles {
    Get-ChildItem -Path $LogPath -Filter $FilePattern |
        Where-Object {
            $_.Name -match "Journal\.(\d{4}-\d{2}-\d{2})" |  Out-Null
            $fileDate = [datetime]::ParseExact($Matches[1], "yyyy-MM-dd", $null)
            $fileDate -ge $startDT.Date -and $fileDate -lt $endDT.Date
        } |
        Sort-Object Name
}

###
# Event processing
###
Function Invoke-StatEvent {
    param($line)

    ### Offline carrier distance: login after carrier jumped
    if ($line.event -eq "LoadGame") {
        # Reset — next Location will tell us where we are
        $Script:pendingCarrierCheck = $true
    }

    if (($line.event -eq "Location") -and $Script:pendingCarrierCheck) {
        $Script:pendingCarrierCheck = $false
        if ($Script:lastStarPos -and $Script:lastOnCarrier -and $line.StarSystem -ne $Script:lastSystem) {
            $newPos = $line.StarPos
            if ($newPos) {
                $dist = Get-Distance -pos1 $Script:lastStarPos -pos2 $newPos
                $stats.CarrierDistance += $dist
            }
        }
        if ($line.StarPos) {
            $Script:lastStarPos   = $line.StarPos
            $Script:lastSystem    = $line.StarSystem
            $Script:lastOnCarrier = ($line.StationType -eq "FleetCarrier")
        }
    }

    ### Track last known position and carrier status before logout
    if ($line.event -eq "Location" -and $line.StarPos) {
        $Script:lastStarPos   = $line.StarPos
        $Script:lastSystem    = $line.StarSystem
        $Script:lastOnCarrier = ($line.StationType -eq "FleetCarrier")
    }

    ### FSD jumps
    if ($line.event -eq "FSDJump") {
        $stats.FsdJumps++
        $stats.FsdDistance += $line.JumpDist
        $stats.SystemsVisited.Add($line.StarSystem) | Out-Null
    }

    ### Supercharged jump (neutron/white dwarf cone boost)
    if ($line.event -eq "JetConeBoost") {
        $stats.FsdSupercharged++
    }

    ### Deaths
    if ($line.event -eq "Died") {
        $stats.Deaths++
    }

    ### Codex entries
    if ($line.event -eq "CodexEntry") {
        $stats.CodexEntries++
    }

    ### First discoveries via Scan
    if ($line.event -eq "Scan" -and $line.WasDiscovered -eq $false) {

        # Systems discovered — star scans only
        if ($line.StarType) {
            $stats.SystemsDiscovered.Add($line.StarSystem) | Out-Null
        }

        # Special planets
        switch ($line.PlanetClass) {
            "Earthlike body"  { $stats.EarthLike++ }
            "Water world"     { $stats.WaterWorld++ }
            "Ammonia world"   { $stats.AmmoniaWorld++ }
        }
        if ($line.TerraformState -eq "Terraformable") { $stats.Terraformable++ }

        # Special stars
        if ($line.StarType) {
            if ($line.StarType -eq "N")                          { $stats.NeutronStar++ }
            elseif ($line.StarType -eq "BH")                     { $stats.BlackHole++ }
            elseif ($line.StarType -match "^D")                  { $stats.WhiteDwarf++ }
            elseif ($line.StarType -match "^W")                  { $stats.WolfRayet++ }
        }
    }
}

###
# Main — process journals
###
$Script:pendingCarrierCheck = $false

$files = Get-JournalFiles
if ($files.Count -eq 0) {
    Write-Host "No journal files found for the specified date range."
    exit
}

foreach ($file in $files) {
    $reader = [System.IO.File]::OpenText($file.FullName)
    while (($read = $reader.ReadLine()) -ne $null) {
        try {
            $line = $read | ConvertFrom-Json
            # Filter events within the date range
            if ($line.timestamp) {
                $ts = [datetime]$line.timestamp
                if ($ts -ge $startDT -and $ts -lt $endDT) {
                    Invoke-StatEvent -line $line
                }
            }
        } catch {}
    }
    $reader.Close()
}

###
# Output report
###
$totalDistance = $stats.FsdDistance + $stats.CarrierDistance
$endLabel      = if ($EndDate) { $EndDate } else { "now" }

Write-Host ""
Write-Host "=================================================="
Write-Host "  Expedition Statistics"
Write-Host "  Period: $StartDate to $endLabel"
Write-Host "=================================================="
Write-Host ""
Write-Host "DISTANCE TRAVELED"
Write-Host ("  FSD:              {0:N1} ly" -f $stats.FsdDistance)
Write-Host ("  Carrier (offline):{0:N1} ly" -f $stats.CarrierDistance)
Write-Host ("  Total:            {0:N1} ly" -f $totalDistance)
Write-Host ""
Write-Host "EXPLORATION"
Write-Host ("  Systems visited:  {0}" -f $stats.SystemsVisited.Count)
Write-Host ("  Systems discovered:{0}" -f $stats.SystemsDiscovered.Count)
Write-Host ("  Codex entries:    {0}" -f $stats.CodexEntries)
Write-Host ""
Write-Host "FSD JUMPS"
Write-Host ("  Total jumps:      {0}" -f $stats.FsdJumps)
Write-Host ("  Supercharged:     {0}" -f $stats.FsdSupercharged)
Write-Host ""
Write-Host "FIRST DISCOVERIES"
Write-Host ("  Earth-like worlds:{0}" -f $stats.EarthLike)
Write-Host ("  Water worlds:     {0}" -f $stats.WaterWorld)
Write-Host ("  Ammonia worlds:   {0}" -f $stats.AmmoniaWorld)
Write-Host ("  Terraformable:    {0}" -f $stats.Terraformable)
Write-Host ("  Neutron stars:    {0}" -f $stats.NeutronStar)
Write-Host ("  White dwarfs:     {0}" -f $stats.WhiteDwarf)
Write-Host ("  Black holes:      {0}" -f $stats.BlackHole)
Write-Host ("  Wolf-Rayet stars: {0}" -f $stats.WolfRayet)
Write-Host ""
if ($stats.Deaths -gt 0) {
    Write-Host ("  Note: {0} death(s) recorded. Distance figures may include recovery travel." -f $stats.Deaths)
    Write-Host ""
}
Write-Host "=================================================="
