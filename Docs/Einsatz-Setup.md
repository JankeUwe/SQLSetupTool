# Einsatzbeschreibung – CLI SQL-Server-Setup

Diese Beschreibung erklärt den **praktischen Einsatz** des kopflosen Setups
(`Start-SqlSetup.ps1`) für die standardisierte Installation von SQL Server
**2019 / 2022 / 2025** – von der Vorbereitung über den Rollout bis zur optionalen
AlwaysOn-Verfügbarkeitsgruppe. Die ausführliche Parameterreferenz steht in
[CLI-Setup.md](CLI-Setup.md).

---

## 1. Wozu dient das Setup?

Das Tool installiert SQL Server **vollständig automatisiert und einheitlich** auf
dbatools-Basis (`Install-DbaInstance`) und führt anschließend die komplette
Standard-Nachkonfiguration durch (Speicher, TempDB, Ports, Berechtigungen, Monitoring,
Wartungsjobs nach Ola Hallengren u. a.). Optional wird bis zur **AlwaysOn-AG** auf einem
bestehenden Cluster durchgelaufen.

Vorteile gegenüber einer manuellen Installation:

- **Reproduzierbar:** Jeder Server wird nach demselben Standard (settings.ini / Domain-Profil)
  installiert – kein „Klick-Drift".
- **Unbeaufsichtigt:** Per `-NonInteractive` ohne Dialoge, z. B. aus Provisioning-Skripten.
- **Nachvollziehbar:** Jeder Lauf schreibt ein Protokoll nach `C:\System\WinSrvLog\MSSQL`.
- **Risikoarm:** `-WhatIf` zeigt vorab exakt, was passieren würde.

Die GUI (`Main.ps1`) bleibt unverändert nutzbar – das CLI ist die unbeaufsichtigte Alternative.

---

## 2. Voraussetzungen (einmalig je Umgebung)

| Bereich | Anforderung |
|---------|-------------|
| **Rechte** | Ausführung als **lokaler Administrator** auf dem Zielserver. Das Skript bricht sonst ab. |
| **Module** | `dbatools` und `sqmSQLTool` erreichbar (Share → lokal → PSGallery, gemäß `settings.ini`). |
| **Medien** | Installationsquellen unter `<InstallDrive>:\SQLSources\SQL<Version>\SQL_Install` (sowie `…\Reporting`, `…\Management`, `…\TDP` für optionale Komponenten). Werden i. d. R. vorab per „Quellen kopieren" bereitgestellt. |
| **Platten** | Die im Disklayout konfigurierten Laufwerke (z. B. G=Data, H=Log, I=TempDB, F=Backup) müssen existieren; empfohlen mit 64 KB Blockgröße. |
| **Dienstkonto** | Bei Domänenkonto: `DOMAIN\User` + Passwort bzw. PSCredential. Ohne Angabe wird das virtuelle Dienstkonto verwendet. |
| **AlwaysOn** | Bestehendes **WSFC**, Ausführung auf einem Cluster-Knoten, Modul `FailoverClusters`, sysadmin auf allen Replikaten. |

---

## 3. Vorbereitung der Konfiguration

Die Installation wird durch **`Config\settings.ini`** (und optional
`Config\domains\<DOMAIN>.ini` / `DEFAULT.ini`) gesteuert. Vor dem ersten Einsatz in einer
Umgebung prüfen:

- `[General]` – `DefaultVersion`, `DefaultEdition`, `DefaultInstanceName`, `SourceShare`
- `[Versions] Available` – verfügbare Versionen (2019,2022,2025)
- `[Editions]` – erlaubte Editionen je Versionsgruppe (z. B. `SQL2025=Developer-Standard,Developer-Enterprise`)
- `[DiskLayout_*]` bzw. Domain-Profil – Laufwerksbuchstaben
- `[Ports]` – `BasePort` / `PortIncrement` (TCP-Port wird aus dem Instanznamen abgeleitet)
- `[OptionalComponents]` / `[Drivers]` – welche Komponenten/Treiber grundsätzlich aktiv sind
- `[Monitoring]`, `[PostInstall]`, `[Qualys]`, `[SysadminGroups]` – Nachkonfiguration

> Domänenspezifische Abweichungen (Sortierung, Disklayout, sysadmin-Gruppen, Quellpfade) gehören
> in `Config\domains\<DOMAIN>.ini`; das Profil hat Vorrang vor den globalen Werten.

CLI-Parameter überschreiben anschließend nur **einzelne** Werte für den jeweiligen Lauf
(z. B. `-Version`, `-Edition`, `-InstanceName`, Laufwerke).

---

## 4. Standard-Rollout (Schritt für Schritt)

### Schritt 1 – Trockenlauf (Pflicht)

Immer zuerst mit `-WhatIf`. Es wird nichts verändert; das Tool gibt Konfigurationsauflösung,
Pfade und den geplanten Ablauf aus.

```bat
Start-SqlSetup.cmd -Version 2022 -Edition Developer -InstanceName MSSQLServer -WhatIf
```

Prüfen: Stimmen Version/Edition/Instanz, Collation, Konto, Komponenten und vor allem die
**Pfade** (Install/Data/Log/TempDB/Backup)?

### Schritt 2 – Installation

Wenn der Plan passt, ohne `-WhatIf` starten. Für vollautomatischen Betrieb `-NonInteractive`
(unterdrückt Dialoge; interaktive PreInstall-Prüfungen werden dann übersprungen).

```bat
Start-SqlSetup.cmd -Version 2022 -Edition Developer -InstanceName MSSQLServer -NonInteractive
```

Ablauf: Verzeichnisse anlegen → `Install-DbaInstance` → optionale Komponenten/Treiber →
PostInstall. Der Fortschritt erscheint auf der Konsole und im Protokoll.

> **Optional – animierter Ablauf:** Mit `-ProgressReport` entsteht zusätzlich eine eigenständige
> animierte HTML-Datei (Phasen-Pipeline mit laufenden Pfeilen, Format-/Installations-/AlwaysOn-Animationen).
> Sie liegt neben dem Log und ist per Doppelklick oder über einen Share abspielbar – ideal als
> nachvollziehbares Artefakt der Installation. Details in [CLI-Setup.md](CLI-Setup.md).

### Schritt 3 – Verifikation

```powershell
Import-Module sqmSQLTool
Get-sqmSQLInstanceCheck -SqlInstance <Instanz>
```

Erwartung: Instanz erreichbar, Standardwerte gesetzt, PostInstall-Report erzeugt.
Bei SQL **2025** den Lauf separat verifizieren (Medien-/dbatools-Unterstützung).

---

## 5. Optionale Komponenten und Treiber

Ohne Angabe werden die in `settings.ini` aktivierten Komponenten installiert (SSMS und SSIS
standardmäßig an – wie in der GUI). Mit `-Component` / `-Driver` gezielt auswählen:

```bat
:: Nur SSMS + SSIS, dazu der ODBC-Treiber
Start-SqlSetup.cmd -Version 2025 -Edition Developer-Standard -InstanceName SQL01 ^
    -Component SSMS,SSIS -Driver ODBC -NonInteractive
```

> SSIS gehört zum Engine-Feature (`IS`). Wird `SSIS` **nicht** gelistet, entfällt `IS` –
> genau wie das Abwählen der GUI-Checkbox.

---

## 6. AlwaysOn-Verfügbarkeitsgruppe (optional)

Auf einem WSFC-Knoten kann das Setup direkt im Anschluss eine AG erstellen:

```bat
Start-SqlSetup.cmd -Version 2022 -NonInteractive -AlwaysOn ^
    -AvailabilityGroupName ProdAG -AgDatabase AppDb
```

Dabei werden Cluster/Knoten und (sofern nicht angegeben) der Listener automatisch erkannt,
HADR aktiviert, Endpoints und AG erstellt, Secondaries beigetreten, Logins synchronisiert und
Autoseeding gesetzt. Fehlen Kerberos-SPNs, eine SQL-Auth-Credential übergeben – das Tool legt
zusätzlich eine **SPN-Anforderungsdatei fürs AD-Team** ab.

AlwaysOn lässt sich auch unabhängig vom Install ausführen:

```powershell
Import-Module sqmSQLTool
Invoke-sqmAlwaysOnSetup -AvailabilityGroupName ProdAG -Database AppDb -WhatIf   # erst Trockenlauf
Invoke-sqmAlwaysOnSetup -AvailabilityGroupName ProdAG -Database AppDb           # dann echt
```

Gesundheit prüfen: `Get-sqmAlwaysOnHealthReport`.

---

## 7. Typische Einsatzszenarien

| Szenario | Aufruf (Kurzform) |
|----------|-------------------|
| Standardinstanz, unbeaufsichtigt | `Start-SqlSetup.cmd -Version 2022 -Edition Developer -NonInteractive` |
| Benannte Instanz, gezielte Komponenten | `… -InstanceName SQL01 -Component SSMS,SSIS -Driver ODBC` |
| Abweichendes Datenlaufwerk | `… -DataDrive E -LogDrive F` |
| Domänen-Dienstkonto | `… -ServiceCredential (Get-Credential)` |
| Nur Engine, ohne Nachkonfiguration | `… -Component @() -SkipPostInstall` |
| Install inkl. AlwaysOn | `… -NonInteractive -AlwaysOn -AvailabilityGroupName ProdAG -AgDatabase AppDb` |

---

## 8. Protokoll & Fehlersuche

- **Protokoll:** Jeder CLI-Lauf schreibt `SqlSetupCli_<Zeitstempel>.log` nach `-LogPath`
  (Standard `C:\System\WinSrvLog\MSSQL`). PostInstall- und AlwaysOn-Schritte loggen zusätzlich
  über `Invoke-sqmLogging`. Mit `-ProgressReport` entstehen dort außerdem `SqlSetup_<Zeitstempel>.events.jsonl`
  (Ereignis-Stream) und `SqlSetup_<Zeitstempel>.html` (animierter Ablauf).
- **Rückgabewerte (Exit Codes):** `0` = OK · `1` = keine Adminrechte / Konfig fehlt ·
  `2` = durch PreInstall abgebrochen · `3` = Installationsfehler · `4` = konfiguriertes Laufwerk fehlt.
- **„Share nicht erreichbar":** kein Beinbruch – das Tool fällt auf lokale Installation/Gallery
  zurück; nur die betroffenen Quellen/Funktionen entfallen.
- **AlwaysOn-Verbindung scheitert:** SPNs prüfen (siehe erzeugte AD-Team-Datei) oder
  `-SqlCredential` für SQL-Authentifizierung übergeben.
- **Wiederholbarkeit:** Die Schritte sind idempotent – ein erneuter Lauf überspringt bereits
  Vorhandenes (Instanz, Endpoint, AG, Listener).

---

## 9. Kurz-Checkliste vor dem Produktiv-Rollout

- [ ] `settings.ini` (und ggf. Domain-Profil) geprüft
- [ ] Installationsmedien unter `…\SQLSources\SQL<Version>` vorhanden
- [ ] Ziel-Laufwerke existieren (möglichst 64 KB Blockgröße)
- [ ] Dienstkonto/Passwort bereit (falls Domänenkonto)
- [ ] **`-WhatIf`-Lauf** durchgeführt und Plan bestätigt
- [ ] Snapshot/Backup des Servers angelegt (bei AlwaysOn: aller Knoten)
- [ ] Nach dem Lauf: `Get-sqmSQLInstanceCheck` grün, Protokoll gesichtet
