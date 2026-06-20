# CLI SQL-Server-Setup (headless)

`Start-SqlSetup.ps1` ist die **kopflose Kommandozeilen-Variante** des SQL Server Setup Tools.
Sie installiert SQL Server **2019 / 2022 / 2025** auf **dbatools-Basis** (`Install-DbaInstance`)
und kann optional bis zur **AlwaysOn-Verfügbarkeitsgruppe** durchlaufen — ohne GUI.

Die vorhandenen GUI-Module werden **unverändert wiederverwendet** (`Config`, `Validation`,
`DiskLayout`, `CopySource`, `Installation`, `PostInstall`, `DbaToolsSetup`, `Drivers`, `PreInstall`)
plus das Modul **sqmSQLTool**. Die Konfiguration ist dieselbe `Config\settings.ini`
(+ `Config\domains\*.ini`) wie bei der GUI; CLI-Parameter überschreiben nur einzelne Werte.

## Voraussetzungen

- Ausführung **als Administrator** (das Skript bricht sonst ab).
- Erreichbares `dbatools` und `sqmSQLTool` (Share → lokal → PSGallery, wie in `settings.ini` konfiguriert).
- Installationsmedien unter `<InstallDrive>:\SQLSources\SQL<Version>\SQL_Install`
  (bzw. `…\Reporting`, `…\Management`, `…\TDP` für optionale Komponenten) — wie bei der GUI.
- Für AlwaysOn: bestehendes **WSFC** und Ausführung auf einem Cluster-Knoten
  (Modul `FailoverClusters`).

## Aufruf

```bat
:: über den .cmd-Launcher (prüft Elevation, leitet alle Argumente weiter)
Start-SqlSetup.cmd -Version 2022 -Edition Developer -NonInteractive

:: oder direkt mit PowerShell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-SqlSetup.ps1 -Version 2022 -NonInteractive
```

### Trockenlauf (empfohlen vor jedem echten Lauf)

```bat
Start-SqlSetup.cmd -Version 2025 -Edition Developer-Standard -InstanceName SQL01 -WhatIf
```

`-WhatIf` löst Konfiguration und Pfade auf, gibt den **Installationsplan** aus und führt
**nichts** aus.

## Parameter

| Parameter | Beschreibung | Standard |
|-----------|--------------|----------|
| `-ConfigPath` | Pfad zur `settings.ini` | `<ScriptDir>\Config\settings.ini` |
| `-Version` | `2019` \| `2022` \| `2025` | `[General] DefaultVersion` |
| `-Edition` | Edition (passend zur Versions-Editionsliste, z. B. `Developer`, `Standard`, `Developer-Standard`) | `DefaultEdition` |
| `-InstanceName` | `MSSQLServer` (Standardinstanz) oder benannte Instanz | `DefaultInstanceName` |
| `-Collation` | Server-Sortierung | aufgelöste Collation |
| `-ServiceAccount` / `-ServicePassword` | SQL-Dienstkonto (`DOMAIN\User` + SecureString) | virtuelles Dienstkonto |
| `-ServiceCredential` | PSCredential (Alternative zu Account/Passwort) | – |
| `-InstallDrive` / `-DataDrive` / `-LogDrive` / `-TempDrive` / `-BackupDrive` | überschreiben das Plattenlayout (einzelner Buchstabe) | aus Disklayout |
| `-Component` | `SSRS,SSAS,SSMS,SSIS,TDP` (Mehrfachauswahl) | in `settings.ini` aktivierte (SSMS+SSIS standardmäßig an) |
| `-Driver` | `JDBC,ODBC,DB2` | aktivierte mit Quellpfad |
| `-MonitoringType` | `0`=keins, `1`=Service, `2`=vollständig | `MonitoringDefault` |
| `-SkipPreInstall` | PreInstall-Prüfungen überspringen (in `-NonInteractive` automatisch) | – |
| `-SkipPostInstall` | PostInstall überspringen | – |
| `-AlwaysOn` | nach PostInstall eine AG erstellen (`Invoke-sqmAlwaysOnSetup`) | – |
| `-AvailabilityGroupName` / `-AgDatabase` / `-AgListenerName` / `-AgListenerIPAddress` / `-AgListenerPort` | AlwaysOn-Parameter (meist aus dem Cluster auto-erkannt) | auto |
| `-NonInteractive` | vollständig unbeaufsichtigt, keine Dialoge | – |
| `-LogPath` | Verzeichnis für das Laufprotokoll | `C:\System\WinSrvLog\MSSQL` |
| `-ProgressReport` | erzeugt einen **animierten HTML-Ablauf-Report** (Replay) | – |
| `-ProgressReportPath` | Zielpfad der HTML-Datei | `<LogPath>\SqlSetup_<Zeitstempel>.html` |
| `-WhatIf` | Trockenlauf, keine Änderungen | – |

> **Hinweis zu PreInstall:** `Invoke-PreInstallChecks` (64K-Format / Snapshot / HPU) nutzt
> interaktive Dialoge und wird daher in `-NonInteractive` automatisch übersprungen.
> Für diese Prüfungen interaktiv ohne `-NonInteractive` starten.

## Ablauf

1. Admin-Prüfung → Module importieren (identisch zu `Main.ps1`).
2. `Get-SetupConfig` (settings.ini + Domain-Profil) → CLI-Parameter überschreiben Einzelwerte.
3. `Assert-DbaToolsReady` / `Assert-sqmSQLToolReady`.
4. `Get-SqlPaths` → Plan ausgeben (bei `-WhatIf` Ende hier).
5. Optional `Invoke-PreInstallChecks` (nur interaktiv).
6. `New-SqlDirectories` → `Invoke-SqlInstallation` (= `Install-DbaInstance`).
7. Optionale Komponenten (`SSAS`/`SSRS`/`TDP`/`SSMS`) und Treiber (`JDBC`/`ODBC`/`DB2`).
8. `Invoke-PostInstall` (Speicher/TempDB/Ports/Monitoring/Ola/…).
9. Bei `-AlwaysOn`: `Invoke-sqmAlwaysOnSetup`.

SSIS gehört zum Engine-Feature (`IS`). Wird `SSIS` **nicht** in `-Component` gelistet, entfernt die
CLI `IS` aus der Feature-Liste (genau wie das Abwählen der GUI-Checkbox).

## AlwaysOn (volle AG-Erstellung)

`-AlwaysOn` ruft `Invoke-sqmAlwaysOnSetup` (Modul **sqmSQLTool**) auf. Dieses:

1. liest **WSFC + Knoten** und (sofern nicht vorgegeben) die **Listener-Rolle** (Name/IP/Port),
2. ermittelt **SQL-Instanz + Dienstkonto** je Knoten,
3. prüft Konnektivität (**Windows-Auth/Kerberos** bevorzugt; bei fehlenden SPNs `-SqlCredential` für SQL-Auth),
4. sichert optional die Cluster-Einstellungen,
5. ruft **`New-sqmAvailabilityGroup`** auf (HADR aktivieren, DBM-Endpoints, `CREATE AVAILABILITY GROUP`
   mit `SEEDING_MODE = AUTOMATIC`, Secondaries `JOIN`, Listener),
6. synchronisiert Logins (`Sync-sqmLoginsToAlwaysOn`) und stellt Autoseeding sicher
   (`Invoke-sqmSqlAlwaysOnAutoseeding`),
7. erzeugt optional eine **SPN-Anforderungsdatei** fürs AD-Team.

Beide Funktionen sind voll `-WhatIf`-fähig und protokollieren über `Invoke-sqmLogging`.

### AlwaysOn direkt (ohne Installation)

```powershell
Import-Module sqmSQLTool
# kompletter Lauf auf dem Cluster-Knoten:
Invoke-sqmAlwaysOnSetup -AvailabilityGroupName ProdAG -Database AppDb

# Trockenlauf mit SQL-Auth:
Invoke-sqmAlwaysOnSetup -AvailabilityGroupName ProdAG -Database AppDb -SqlCredential (Get-Credential sa) -WhatIf

# nur die AG-Kernerstellung, parametergetrieben:
New-sqmAvailabilityGroup -SqlInstance SQL01 -SecondaryReplica SQL02,SQL03 `
    -AvailabilityGroupName ProdAG -Database AppDb `
    -ListenerName ProdAGL -ListenerIPAddress 10.0.0.50 -ListenerPort 1433 `
    -ServiceAccount 'CONTOSO\svcSql'
```

## Beispiele

```bat
:: Unbeaufsichtigte Standardinstanz, SQL 2022 Developer
Start-SqlSetup.cmd -Version 2022 -Edition Developer -NonInteractive

:: Benannte Instanz, SQL 2025, nur SSMS+SSIS, ODBC-Treiber, Trockenlauf
Start-SqlSetup.cmd -Version 2025 -Edition Developer-Standard -InstanceName SQL01 -Component SSMS,SSIS -Driver ODBC -WhatIf

:: Install + PostInstall + AlwaysOn-AG
Start-SqlSetup.cmd -Version 2022 -NonInteractive -AlwaysOn -AvailabilityGroupName ProdAG -AgDatabase AppDb
```

## Animierter Ablauf-Report (optional)

Mit `-ProgressReport` schreibt das Setup zusätzlich zum Text-Log einen **Ereignis-Stream**
(JSON-Lines) und erzeugt am Ende eine **eigenständige animierte HTML-Datei** (Replay): eine
Phasen-Pipeline (Quellen → PreInstall → Verzeichnisse → Installation → Komponenten → Treiber →
PostInstall → AlwaysOn) mit passenden Animationen je Schritt – laufende Pfeile bei der Kopie,
Füll-Animation beim Formatieren, Zahnräder bei Installation/PostInstall, rotierender „Restarte
Node" und Replikations-Pfeile bei AlwaysOn. Die Datei ist **offline** (kein CDN) und per Doppelklick
oder über einen Share abspielbar (Play/Pause, Scrubber).

```bat
:: erzeugt …\SqlSetup_<Zeitstempel>.html neben dem Log
Start-SqlSetup.cmd -Version 2022 -Edition Developer -NonInteractive -ProgressReport

:: eigener Zielpfad
Start-SqlSetup.cmd -Version 2022 -NonInteractive -ProgressReport -ProgressReportPath C:\Temp\setup.html

:: Trockenlauf-Report (geplanter Ablauf, ohne Ausführung)
Start-SqlSetup.cmd -Version 2025 -Edition Developer-Standard -WhatIf -ProgressReport
```

Technisch: die sqm-Funktionen `Write-sqmSetupEvent` (Emitter) und `New-sqmSetupReport` (HTML-Generator)
sind entkoppelt – ohne `-ProgressReport` verhält sich das Setup exakt wie zuvor, und ein Fehler im
Report kann die Installation nicht beeinträchtigen. `Invoke-sqmAlwaysOnSetup` akzeptiert dafür einen
`-EventLog <Pfad>`, sodass auch der eigenständige AlwaysOn-Lauf einen Report speisen kann.

## Verifikation

- **Dry-Run:** `Start-SqlSetup.ps1 -WhatIf` → Konfigurationsauflösung, Pfade und geplante Schritte
  ohne Ausführung. Mit zusätzlich `-ProgressReport` entsteht ein Replay des geplanten Ablaufs.
- **Lab-VM:** unbeaufsichtigte Installation 2019/2022, danach `Get-sqmSQLInstanceCheck` grün und
  PostInstall-Report erzeugt. SQL 2025 separat verifizieren (Medien/dbatools-Unterstützung).
- **AlwaysOn:** 2–3-Knoten-WSFC-Lab → `Invoke-sqmAlwaysOnSetup` → `Get-sqmAlwaysOnHealthReport`
  zeigt gesunde AG + Listener.
- **Pester:** `Invoke-Pester` über `tests\Unit\Public\New-sqmAvailabilityGroup.Tests.ps1` (15 Tests, gemockt).

> Die bestehenden GUI-Module werden nicht verändert — der GUI-Pfad (`Main.ps1`) bleibt unberührt.
