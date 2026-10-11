# Save.TV for Mac

Inoffizieller macOS-Client für [Save.TV](https://www.save.tv): lädt fertige Aufnahmen automatisch
auf den Mac (werbefrei, fortsetzbar, mit Metadaten), zeigt das TV-Programm, programmiert Aufnahmen
und verwaltet Serien-Abos – als Ersatz für den eingestellten Save.TV-Downloadmanager.

*Unofficial macOS client for the German online video recorder Save.TV. Downloads finished recordings
automatically, browses the EPG, schedules recordings and manages series subscriptions. German UI.*

> **Hinweis:** Dieses Projekt steht in keiner Verbindung zur Save.TV GmbH. Es nutzt die Aufrufe der
> Save.TV-Website mit dem eigenen Mitgliedskonto – nur für den privaten Gebrauch mit dem eigenen Account.
> Ändert Save.TV die Website, kann die Funktion ausfallen. Keine Gewähr.

## Funktionen

- **Archiv** – fertige Aufnahmen mit Vorschaubild, Status, Detailansicht; Doppelklick spielt ab oder lädt;
  Rechtsklick: Abspielen, Im Finder zeigen, Erneut laden, lokal / bei Save.TV löschen
- **Programm** – Jetzt · Gleich · 20:15 · 22:15 · Highlights · **Genres** (mit Subgenres) · Suche,
  Senderfilter, Beschreibung, **Aufnehmen**, **Alle Folgen aufnehmen (Abo)**
- **Geplant** – programmierte Aufnahmen ansehen und löschen
- **Abos** – Save.TV-Channels anlegen/löschen (neue Folgen werden automatisch aufgenommen und geladen)
- **Downloads** – nur werbefreie Fassung (optional), bis zu 3 parallel, Fortschritt mit Geschwindigkeit
  und Restzeit, fortsetzbar, Prüfung der fertigen Datei, Metadaten in die MP4 (AtomicParsley/ffmpeg)
- **Automatik** – Hintergrundlauf nach Intervall oder sobald eine geplante Aufnahme geendet hat,
  Mitteilungen, Start bei Anmeldung, Aufräumregeln (Alter / freier Speicher), Menüleisten-Symbol
- **Diagnose** (⌘D) prüft alle Bausteine und zeigt die Ursache bei Problemen

Das Passwort liegt ausschließlich im macOS-Schlüsselbund.

## Installation

Voraussetzungen: macOS 11 oder neuer, Xcode Command Line Tools (`xcode-select --install`).
Python 3 ist bei macOS dabei; es werden keine Zusatzpakete benötigt.

```bash
git clone https://github.com/sporcherla/save.tv-for-mac.git
cd save.tv-for-mac/app
bash build.sh
open "Save.TV Downloader.app"      # optional: nach /Applications kopieren
```

Beim ersten Start führt ein Assistent durch Konto, Login-Test und Zielordner.

Optional für Metadaten in den Videodateien: `brew install atomicparsley` (oder `ffmpeg`).

## Nur das Skript (ohne App)

```bash
python3 savetv_dl.py --setup      # Einrichtung (Passwort → Schlüsselbund)
python3 savetv_dl.py --list       # Archiv anzeigen
python3 savetv_dl.py              # neue Aufnahmen laden
python3 savetv_dl.py --selftest   # Diagnose
```

Für den Hintergrundbetrieb ohne App: `de.savetv-dl.plist` anpassen (Pfad eintragen) und nach
`~/Library/LaunchAgents/` kopieren, dann `launchctl load ~/Library/LaunchAgents/de.savetv-dl.plist`.
Weitere Befehle: `python3 savetv_dl.py --help`.

## Dateien

| Pfad | Zweck |
|---|---|
| `savetv_dl.py` | Kern: Login, Archiv, Programm, Aufnahmen, Abos, Downloads (Python 3, Standardbibliothek) |
| `app/main.swift` | macOS-App (AppKit), steuert das Skript |
| `app/build.sh` | baut `Save.TV Downloader.app` inkl. Icon |
| `~/.savetv-dl/` | Konfiguration (`config.json`), Erledigt-Liste, Protokoll, Sitzung |

Liegt neben der App eine neuere `savetv_dl.py`, wird sie automatisch verwendet (kein Neubau nötig).

## Einstellungen (config.json)

| Schlüssel | Bedeutung |
|---|---|
| `format_priority` | z. B. `["hd","sd","mobil"]` |
| `adfree_only` | nur werbefrei laden, sonst auf Schnittliste warten (Standard: ja) |
| `skip_marked_downloaded` | Aufnahmen überspringen, die Save.TV schon als geladen markiert |
| `delete_after_download` | Aufnahme nach dem Download bei Save.TV löschen |
| `parallel_downloads` | gleichzeitige Downloads (1–3) |
| `write_metadata` | Titel/Folge/Beschreibung in die MP4 schreiben |
| `max_downloads_per_run`, `min_age_minutes` | Limit pro Lauf, Wartezeit nach Sendeende |
| `cleanup_days`, `cleanup_min_free_gb` | Aufräumregeln (0 = aus) |
| `filename_pattern` | Platzhalter `{date} {title} {subtitle} {episode} {station} {format} {adfree} {id}` |

## Technik

Website-Login per Cookie, Archiv über `VideoArchiveApi.cfm`, Programm über `ListingAPI.cfm`,
Aufnahmen über `tcJWriteRecord.cfm`, Download-Links über `croGetDownloadUrl2.cfm`, Abos über
`createChannel.cfm` – derselbe Weg, den auch [stv-catchall](https://github.com/einstweilen/stv-catchall)
und JDownloader nutzen. Save.TV bietet zusätzlich eine dokumentierte REST-API (api.save.tv/v3), die
jedoch einen OAuth-Client benötigt, der nicht öffentlich vergeben wird.

## Lizenz

MIT – siehe [LICENSE](LICENSE). „Save.TV“ ist eine Marke der Save.TV GmbH.
