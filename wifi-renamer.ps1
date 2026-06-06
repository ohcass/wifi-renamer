$ESC = [char]27

function Color($code, $text) {
    "$ESC[${code}m$text$ESC[0m"
}

$BackupFile = Join-Path $env:ProgramData "wifi-renamer-backups.json"

$BackupFile = Join-Path $env:ProgramData "wifi-renamer-backups.txt"

function Load-Backups {

    $table = @{}

    if (Test-Path $BackupFile) {

        foreach ($line in Get-Content $BackupFile) {

            if ($line -match '^(.+?)=(.+)$') {
                $table[$matches[1]] = $matches[2]
            }
        }
    }

    return $table
}

function Save-Backups($table) {

    $lines = foreach ($key in $table.Keys) {
        "$key=$($table[$key])"
    }

    $lines | Set-Content $BackupFile
}

function Show-Header {
    Write-Host ""
    Write-Host "  $(Color '96;1' 'wifi-rename')" -NoNewline
    Write-Host "  $(Color '90' 'WiFi profile renamer')"
    Write-Host "  ====================================="
    Write-Host ""
}

function Get-WifiProfiles {
    netsh wlan show profiles |
    Select-String "All User Profile" |
    ForEach-Object {
        ($_ -split ':', 2)[1].Trim()
    }
}

function Show-ProfileList($profiles, $title) {
    Write-Host "  $(Color '33' $title)"
    Write-Host ""

    for ($i = 0; $i -lt $profiles.Count; $i++) {
        Write-Host "  $(Color '90' "$($i + 1).")  $($profiles[$i])"
    }

    Write-Host ""
}

function Export-WifiProfile($profileName) {

    $tempPath = $env:TEMP

    Get-ChildItem "$tempPath\*.xml" -ErrorAction SilentlyContinue |
        Remove-Item -Force

    netsh wlan export profile name="$profileName" folder="$tempPath" key=clear | Out-Null

    Start-Sleep -Milliseconds 500

    Get-ChildItem "$tempPath\*.xml" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Rename-WifiProfile($oldName, $newName) {

    $exportedFile = Export-WifiProfile $oldName

    if (-not $exportedFile) {
        Write-Host "  $(Color '31' 'X') Could not export profile."
        return $false
    }

    try {

        [xml]$profileXml = Get-Content $exportedFile.FullName

        $profileXml.WLANProfile.name = [string]$newName

        $newFile = Join-Path $env:TEMP "wifi-profile-renamed.xml"
        $profileXml.Save($newFile)

        netsh wlan delete profile name="$oldName" | Out-Null

        $result = netsh wlan add profile filename="$newFile"

        Remove-Item $exportedFile.FullName, $newFile -Force -ErrorAction SilentlyContinue

        return ($LASTEXITCODE -eq 0 -or $result -match "added")
    }
    catch {

        Write-Host ""
        Write-Host "  $(Color '31' 'X') $($_.Exception.Message)"
        return $false
    }
}

function Reset-WifiProfile($currentName) {

    $backups = Load-Backups

    if (-not $backups.ContainsKey($currentName)) {
        Write-Host "  $(Color '31' 'X') No original name stored."
        return $false
    }

    $originalName = $backups[$currentName]

    if (Rename-WifiProfile $currentName $originalName) {

        $backups.Remove($currentName)
        Save-Backups $backups

        Write-Host ""
        Write-Host "  $(Color '32' 'OK') Restored original name: $(Color '96' $originalName)"

        return $true
    }

    return $false
}

function Test-Administrator {

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

if (-not (Test-Administrator)) {

    Write-Host ""
    Write-Host "Administrator required."
    pause
    exit
}

while ($true) {

    Show-Header

    $profiles = @(Get-WifiProfiles)

    if ($profiles.Count -eq 0) {

        Write-Host "  $(Color '31' 'X') No WiFi profiles found."
        Write-Host ""

        pause
        exit
    }

    Show-ProfileList $profiles "Saved WiFi profiles"

    Write-Host "  $(Color '90' 'Actions:')"
    Write-Host "  $(Color '96' 'r')  rename a profile"
    Write-Host "  $(Color '96' 'x')  restore original name"
    Write-Host "  $(Color '96' 'q')  quit"
    Write-Host ""

    switch ((Read-Host "  $(Color '90' '>')").ToLower()) {

        'q' {
            exit
        }

        'r' {

            Show-Header
            Show-ProfileList $profiles "Select profile to rename"

            $selectedIndex = ([int](Read-Host "  $(Color '90' 'Number')")) - 1

            if ($selectedIndex -lt 0 -or $selectedIndex -ge $profiles.Count) {

                Write-Host "  $(Color '31' 'X') Invalid selection."
                Start-Sleep -Seconds 1
                continue
            }

            $oldName = $profiles[$selectedIndex]

            Write-Host ""
            Write-Host "  Renaming $(Color '33' $oldName)"

            $newName = Read-Host "  $(Color '90' 'New name')"

            if ([string]::IsNullOrWhiteSpace($newName)) {

                Write-Host "  $(Color '31' 'X') Name cannot be empty."
                Start-Sleep -Seconds 1
                continue
            }

            if ($newName -eq $oldName) {

                Write-Host "  $(Color '90' '-') Name unchanged."
                Start-Sleep -Seconds 1
                continue
            }

            Write-Host ""
            Write-Host "  $(Color '90' '...')" -NoNewline

            if (Rename-WifiProfile $oldName $newName) {

                $backups = Load-Backups

                if ($backups.ContainsKey($oldName)) {

                    $originalName = $backups[$oldName]
                    $backups.Remove($oldName)
                    $backups[$newName] = $originalName
                }
                else {

                    $backups[$newName] = $oldName
                }

                Save-Backups $backups

                Write-Host "`r  $(Color '32' 'OK') Renamed to $(Color '96' $newName)"
                Write-Host ""
                Write-Host "  $(Color '90' 'Reconnect to the network for changes to take effect.')"
            }
            else {

                Write-Host "`r  $(Color '31' 'X') Rename failed."
            }

            Write-Host ""
            Read-Host "  $(Color '90' 'Press Enter to continue')" | Out-Null
        }

        'x' {

            $backups = Load-Backups

            $restorable = @(
                $profiles | Where-Object {
                    $backups.ContainsKey($_)
                }
            )

            if ($restorable.Count -eq 0) {

                Write-Host ""
                Write-Host "  $(Color '31' 'X') No renamed profiles found."
                Write-Host ""

                Read-Host "  $(Color '90' 'Press Enter to continue')" | Out-Null
                continue
            }

            Show-Header
            Show-ProfileList $restorable "Profiles that can be restored"

            $selectedIndex = ([int](Read-Host "  $(Color '90' 'Number')")) - 1

            if ($selectedIndex -lt 0 -or $selectedIndex -ge $restorable.Count) {

                Write-Host "  $(Color '31' 'X') Invalid selection."
                Start-Sleep -Seconds 1
                continue
            }

            Reset-WifiProfile $restorable[$selectedIndex]

            Write-Host ""
            Read-Host "  $(Color '90' 'Press Enter to continue')" | Out-Null
        }
    }
}