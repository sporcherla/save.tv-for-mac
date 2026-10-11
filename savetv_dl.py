#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
savetv_dl.py – Automatischer Download der eigenen Save.TV-Aufnahmen (macOS).

Nutzt ausschließlich die Python-Standardbibliothek (kein pip nötig).
Ablauf:  Login (Cookie)  ->  Videoarchiv abfragen  ->  neue Aufnahmen laden
         ->  Download fortsetzbar (.part)  ->  Erledigt-Liste pflegen
         ->  optional Aufnahme bei Save.TV löschen.

Aufruf:
    python3 savetv_dl.py                # Normalbetrieb (z. B. per launchd)
    python3 savetv_dl.py --list         # nur anzeigen, nichts laden
    python3 savetv_dl.py --dry-run      # Download simulieren
    python3 savetv_dl.py --setup        # Konfiguration interaktiv anlegen
    python3 savetv_dl.py --dump         # Roh-JSON zur Fehlersuche speichern
"""

import argparse
import fcntl
import shutil
import signal
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
import getpass
import http.cookiejar
import json
import logging
import os
import re
import subprocess
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

VERSION = "1.0.0"
BASE = "https://www.save.tv"
URL_LOGIN = BASE + "/STV/M/Index.cfm?sk=PREMIUM"
URL_USERCONFIG = BASE + "/STV/M/obj/user/JSON/userConfigApi.cfm?iFunction=2"
URL_ARCHIVE_OPTS = BASE + "/STV/M/obj/user/submit/submitVideoArchiveOptions.cfm"
URL_ARCHIVE = BASE + "/STV/M/obj/archive/JSON/VideoArchiveApi.cfm"
URL_DL_URL = BASE + "/STV/M/obj/cRecordOrder/croGetDownloadUrl2.cfm"
URL_DELETE = BASE + "/STV/M/obj/cRecordOrder/croDelete.cfm"
URL_EPG_PAGE = BASE + "/STV/M/obj/TVProgCtr/TvProgrammSuche.cfm?sSearchString=a"
URL_EPG_LIST = BASE + "/STV/M/obj/TVProgCtr/JSON/ListingAPI.cfm"
URL_EPG_RECORD = BASE + "/STV/M/obj/TC/tcJWriteRecord.cfm"
URL_CH_LIST = BASE + "/STV/M/obj/channels/JSON/myChannelsApi.cfm?iFunction=1"
URL_CH_CREATE = BASE + "/STV/M/obj/channels/createChannel.cfm"
URL_CH_DELETE = BASE + "/STV/M/obj/channels/deleteChannel.cfm"
EPG_MODES = {"now": 1, "next": 2, "prime": 3, "late": 4, "search": 6, "highlights": 7, "genre": 9}
URL_CATEGORIES = BASE + "/STV/S/obj/JSON/TvCategoriesApi.cfm"
URL_STATIONS = BASE + "/STV/M/obj/JSON/TvStationGroupsApi.cfm?iFunction=2&loadTvStationsWithAllStationOption=true&bIsMemberarea=true"

FORMAT_NAMES = {6: "HD", 5: "SD", 4: "Mobil"}
FORMAT_IDS = {"hd": 6, "sd": 5, "mobil": 4, "mobile": 4}

CONF_DIR = Path.home() / ".savetv-dl"
CONF_FILE = CONF_DIR / "config.json"
STATE_FILE = CONF_DIR / "done.json"
COOKIE_FILE = CONF_DIR / "cookies.txt"
LOG_FILE = CONF_DIR / "savetv-dl.log"
LOCK_FILE = CONF_DIR / "run.lock"
KEYCHAIN_SERVICE = "savetv-dl"

DEFAULT_CONFIG = {
    "username": "",
    "password": "",                 # leer lassen, wenn Passwort im Schlüsselbund liegt
    "use_keychain": True,           # Passwort aus macOS-Schlüsselbund (Service: savetv-dl)
    "target_dir": str(Path.home() / "Movies" / "Save.TV"),
    "format_priority": ["hd", "sd", "mobil"],
    "adfree": True,                 # Schnittliste (werbefrei) anwenden
    "adfree_only": True,            # NUR werbefrei laden; ohne Schnittliste warten statt ungeschnitten laden
    "delete_after_download": False, # Aufnahme nach erfolgreichem Download bei Save.TV löschen
    "max_downloads_per_run": 10,
    "min_age_minutes": 30,          # Aufnahmen erst laden, wenn das Sendeende mind. so lange her ist
    "skip_marked_downloaded": True, # Aufnahmen überspringen, die Save.TV bereits als heruntergeladen kennzeichnet
    "parallel_downloads": 2,        # gleichzeitige Downloads (1-3)
    "write_metadata": True,         # Titel/Folge/Beschreibung in die MP4 schreiben (AtomicParsley oder ffmpeg nötig)
    "cleanup_days": 0,              # lokale Aufnahmen älter als X Tage löschen (0 = aus)
    "cleanup_min_free_gb": 0,       # älteste Aufnahmen löschen, bis mindestens X GB frei sind (0 = aus)
    "filename_pattern": "{date} {title}{subtitle}{episode} [{station}] {adfree}",
    "user_agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                  "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
}

log = logging.getLogger("savetv")
STOP = threading.Event()   # wird bei Abbruch (Ctrl+C / App) gesetzt


def _on_signal(signum, frame):
    STOP.set()


signal.signal(signal.SIGINT, _on_signal)
signal.signal(signal.SIGTERM, _on_signal)


# --------------------------------------------------------------------------- #
# Hilfsfunktionen
# --------------------------------------------------------------------------- #
def ci_get(d, *keys, default=None):
    """Case-insensitiver Zugriff auf Dict-Schlüssel (Save.TV liefert GROSSBUCHSTABEN)."""
    if not isinstance(d, dict):
        return default
    lower = {str(k).lower(): v for k, v in d.items()}
    for k in keys:
        v = lower.get(k.lower())
        if v not in (None, ""):
            return v
    return default


def to_int(v, default=0):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return default


def find_key_recursive(obj, key):
    """Sucht rekursiv nach einem Schlüssel (case-insensitiv) und gibt den ersten Wert zurück."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            if str(k).lower() == key.lower():
                return v
        for v in obj.values():
            r = find_key_recursive(v, key)
            if r is not None:
                return r
    elif isinstance(obj, list):
        for v in obj:
            r = find_key_recursive(v, key)
            if r is not None:
                return r
    return None


def safe_filename(name, maxlen=180):
    name = unicodedata.normalize("NFC", str(name))
    name = re.sub(r'[\\/:*?"<>|\r\n\t]+', " ", name)
    name = re.sub(r"\s+", " ", name).strip(" .")
    return name[:maxlen] or "Aufnahme"


def parse_stv_date(s):
    """Save.TV-Datumsformate: '2026-09-24 20:15:00', 'September, 24 2026 20:15:00', ISO."""
    if not s:
        return None
    s = str(s).strip()
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d",
                "%B, %d %Y %H:%M:%S", "%d.%m.%Y %H:%M:%S", "%d.%m.%Y %H:%M"):
        try:
            return datetime.strptime(s[:len(datetime.now().strftime(fmt))], fmt)
        except ValueError:
            continue
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})", s)
    if m:
        return datetime(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    return None


def human_size(n):
    n = float(n or 0)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} PB"


# --------------------------------------------------------------------------- #
# Konfiguration / Schlüsselbund
# --------------------------------------------------------------------------- #
def keychain_get(account):
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", account, "-w"],
            capture_output=True, text=True, check=True)
        return out.stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def keychain_set(account, password):
    subprocess.run(
        ["security", "add-generic-password", "-U", "-s", KEYCHAIN_SERVICE, "-a", account,
         "-w", password, "-l", "Save.TV Downloader"],
        check=True, capture_output=True)


def load_config():
    if not CONF_FILE.exists():
        sys.exit(f"Keine Konfiguration gefunden. Bitte zuerst ausführen:  python3 {sys.argv[0]} --setup")
    cfg = dict(DEFAULT_CONFIG)
    with open(CONF_FILE, encoding="utf-8") as fh:
        cfg.update(json.load(fh))
    if not cfg.get("password"):
        if cfg.get("use_keychain"):
            cfg["password"] = keychain_get(cfg["username"]) or ""
        cfg["password"] = cfg["password"] or os.environ.get("STV_PASS", "")
    cfg["username"] = cfg["username"] or os.environ.get("STV_USER", "")
    if not cfg["username"] or not cfg["password"]:
        sys.exit("Benutzername/Passwort fehlen (config.json, Schlüsselbund oder STV_USER/STV_PASS).")
    return cfg


def setup_interactive():
    CONF_DIR.mkdir(parents=True, exist_ok=True)
    cfg = dict(DEFAULT_CONFIG)
    if CONF_FILE.exists():
        with open(CONF_FILE, encoding="utf-8") as fh:
            cfg.update(json.load(fh))
    print("Save.TV Downloader – Einrichtung\n")
    cfg["username"] = input(f"Save.TV Benutzername [{cfg['username']}]: ").strip() or cfg["username"]
    pw = getpass.getpass("Save.TV Passwort (wird im macOS-Schlüsselbund gespeichert): ")
    if pw:
        try:
            keychain_set(cfg["username"], pw)
            cfg["use_keychain"] = True
            cfg["password"] = ""
            print("  -> Passwort im Schlüsselbund abgelegt.")
        except Exception as e:  # noqa
            print(f"  ! Schlüsselbund nicht verfügbar ({e}); Passwort wird in config.json gespeichert.")
            cfg["password"] = pw
            cfg["use_keychain"] = False
    td = input(f"Zielordner [{cfg['target_dir']}]: ").strip() or cfg["target_dir"]
    cfg["target_dir"] = str(Path(td).expanduser())
    fmt = input("Bevorzugtes Format hd/sd/mobil [hd]: ").strip().lower() or "hd"
    order = [fmt] + [f for f in ("hd", "sd", "mobil") if f != fmt]
    cfg["format_priority"] = order
    cfg["adfree"] = (input("Werbefrei (Schnittliste) bevorzugen? [J/n]: ").strip().lower() or "j") != "n"
    cfg["delete_after_download"] = (input("Nach Download bei Save.TV löschen? [j/N]: ").strip().lower() == "j")
    with open(CONF_FILE, "w", encoding="utf-8") as fh:
        json.dump(cfg, fh, indent=2, ensure_ascii=False)
    os.chmod(CONF_FILE, 0o600)
    Path(cfg["target_dir"]).mkdir(parents=True, exist_ok=True)
    print(f"\nKonfiguration gespeichert: {CONF_FILE}")
    print(f"Test:  python3 {sys.argv[0]} --list")


# --------------------------------------------------------------------------- #
# HTTP-Client
# --------------------------------------------------------------------------- #
class StvClient:
    def __init__(self, cfg):
        self.cfg = cfg
        self.jar = http.cookiejar.MozillaCookieJar(str(COOKIE_FILE))
        if COOKIE_FILE.exists():
            try:
                self.jar.load(ignore_discard=True, ignore_expires=True)
            except Exception:  # noqa
                pass
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))
        self.opener.addheaders = [
            ("User-Agent", cfg["user_agent"]),
            ("Accept", "application/json, text/javascript, */*; q=0.01"),
            ("Accept-Language", "de-DE,de;q=0.9"),
            ("X-Requested-With", "XMLHttpRequest"),
        ]

    _relogin_done = False

    def _req(self, url, data=None, timeout=60, raw=False, _retry_login=True):
        body = None
        if data is not None:
            body = urllib.parse.urlencode(data).encode("utf-8") if isinstance(data, dict) else data.encode("utf-8")
        req = urllib.request.Request(url, data=body)
        if body is not None:
            req.add_header("Content-Type", "application/x-www-form-urlencoded; charset=UTF-8")
        last = None
        for attempt in range(4):
            try:
                with self.opener.open(req, timeout=timeout) as resp:
                    content = resp.read()
                    final_url = resp.geturl() or ""
                    text = None if raw else content.decode("utf-8", "replace")
                    # Sitzung abgelaufen? Save.TV leitet auf die Login-Seite um.
                    if _retry_login and not self._relogin_done and url != URL_LOGIN and (
                            "usShowLogin.cfm" in final_url or (text is not None and "MSG_LOGOUT" in text)):
                        log.warning("Sitzung abgelaufen – melde neu an.")
                        self._relogin_done = True
                        if self.login(force=True):
                            self._relogin_done = False
                            return self._req(url, data, timeout, raw, _retry_login=False)
                        raise RuntimeError("Neu-Anmeldung fehlgeschlagen")
                    return content if raw else text
            except urllib.error.HTTPError as e:
                last = e
                if e.code < 500 or attempt == 3:
                    raise
                log.warning("Serverfehler %s, neuer Versuch in %d s …", e.code, 5 * (attempt + 1))
            except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as e:
                last = e
                if attempt == 3:
                    raise
                log.warning("Netzfehler (%s), neuer Versuch in %d s …", e, 5 * (attempt + 1))
            time.sleep(5 * (attempt + 1))
        raise last or RuntimeError("Anfrage fehlgeschlagen")

    def _json(self, url, data=None):
        txt = self._req(url, data)
        txt = txt.strip().lstrip("﻿")
        # ColdFusion liefert gelegentlich "//" oder Whitespace vor dem JSON
        start = min([i for i in (txt.find("{"), txt.find("[")) if i >= 0] or [0])
        try:
            return json.loads(txt[start:])
        except json.JSONDecodeError:
            log.debug("Kein JSON: %s", txt[:300])
            return None

    def save_cookies(self):
        CONF_DIR.mkdir(parents=True, exist_ok=True)
        lock = CONF_DIR / "cookies.lock"
        with open(lock, "w") as lf:
            fcntl.flock(lf, fcntl.LOCK_EX)
            try:
                self.jar.save(ignore_discard=True, ignore_expires=True)
                os.chmod(COOKIE_FILE, 0o600)
            finally:
                fcntl.flock(lf, fcntl.LOCK_UN)

    # --- Login --------------------------------------------------------------
    def logged_in(self):
        try:
            d = self._json(URL_USERCONFIG)
        except Exception:  # noqa
            return False
        return isinstance(d, dict) and find_key_recursive(d, "CURRENTARTICLEID") is not None

    def login(self, force=False):
        if not force and self.logged_in():
            log.info("Bestehende Sitzung gültig.")
            return True
        if force:
            self.jar.clear()
        log.info("Anmeldung bei Save.TV als %s …", self.cfg["username"])
        txt = self._req(URL_LOGIN, {
            "sUsername": self.cfg["username"],
            "sPassword": self.cfg["password"],
            "bAutoLoginActivate": "1",
        }, _retry_login=False)
        ok = "Login_Succeed" in txt or self.logged_in()
        if not ok:
            if "verifizieren" in txt.lower() or "ungültig" in txt.lower():
                log.error("Login abgelehnt – Benutzername/Passwort prüfen.")
            else:
                log.error("Login fehlgeschlagen (unerwartete Antwort, %d Zeichen).", len(txt))
            return False
        self.save_cookies()
        log.info("Login erfolgreich.")
        return True

    # --- Archiv -------------------------------------------------------------
    def archive_page(self, page, per_page=35, state=1):
        return self._json(URL_ARCHIVE, {
            "iEntriesPerPage": per_page,
            "iCurrentPage": page,
            "iFilterType": 1,
            "sSearchString": "",
            "iTextSearchType": 0,
            "iChannelIds": 0,
            "iTvCategoryId": 0,
            "iTvSubCategoryId": 0,
            "bShowNoFollower": "false",
            "iRecordingState": state,      # 1 = abgeschlossen, 2 = programmiert, 0 = alle
            "sSortOrder": "StartDateDESC",
            "iTvStationGroupId": 0,
            "iRecordAge": 0,
            "iDaytime": 0,
            "manualRecords": "false",
            "dStartdate": "2000-01-01",
            "dEnddate": "2038-01-01",
            "iTvCategoryWithSubCategoriesId": 0,
            "iTvStationId": 0,
            "bHighlightActivation": "false",
            "bVideoArchiveGroupOption": 0,
            "bShowRepeatitionActivation": "false",
        })

    def list_recordings(self, dump=False):
        # ungruppierte Darstellung erzwingen, sonst fehlen Einzelfolgen
        try:
            self._req(URL_ARCHIVE_OPTS, "ShowGroupedVideoArchive=false")
        except Exception:  # noqa
            pass
        recs, page, total_pages = [], 1, 1
        while page <= total_pages:
            d = self.archive_page(page)
            if not isinstance(d, dict):
                log.error("Archivantwort nicht lesbar (Seite %d).", page)
                break
            if dump:
                CONF_DIR.mkdir(parents=True, exist_ok=True)
                with open(CONF_DIR / f"dump_archive_p{page}.json", "w", encoding="utf-8") as fh:
                    json.dump(d, fh, indent=1, ensure_ascii=False)
            total_pages = max(1, to_int(find_key_recursive(d, "ITOTALPAGES"), 1))
            entries = find_key_recursive(d, "ARRVIDEOARCHIVEENTRIES") or []
            for e in entries:
                r = self._parse_entry(e)
                if r:
                    recs.append(r)
            page += 1
            if page > 200:
                break
        return recs

    def _parse_entry(self, e):
        te = ci_get(e, "STRTELECASTENTRY", default=e)
        tid = to_int(ci_get(te, "ITELECASTID", "TELECASTID", "LTELECASTID"))
        if not tid:
            m = re.search(r"TelecastId=(\d+)", str(ci_get(te, "SDETAILSURL", default="")), re.I)
            tid = to_int(m.group(1)) if m else 0
        if not tid:
            m = re.search(r"TelecastId=(\d+)", json.dumps(e), re.I)
            tid = to_int(m.group(1)) if m else 0
        if not tid:
            return None
        formats = []
        for f in (ci_get(e, "ARRALLOWDDOWNLOADFORMATS") or ci_get(te, "ARRALLOWDDOWNLOADFORMATS") or []):
            fid = to_int(ci_get(f, "RECORDINGFORMATID", "IRECORDINGFORMATID", "ID"))
            if fid in FORMAT_NAMES:
                formats.append(fid)
        adfree_raw = ci_get(e, "BADFREEAVAILABLE", default=ci_get(te, "BADFREEAVAILABLE", default=None))
        adfree = str(adfree_raw).lower() in ("1", "1.0", "true", "yes")
        start = parse_stv_date(ci_get(te, "DSTARTDATE", "STARTDATE"))
        end = parse_stv_date(ci_get(te, "DENDDATE", "ENDDATE"))
        tags = [str(ci_get(t, "key", default="")) for t in (ci_get(te, "TAGS") or []) if isinstance(t, dict)]
        return {
            "image": str(ci_get(te, "STELECASTIMGURL", default="")),
            "description": str(ci_get(te, "STHEMA", default="")).strip(),
            "station_image": str(ci_get(te, "STVSTATIONIMGURL", default="")),
            "days_left": to_int(ci_get(te, "IDAYSLEFTBEFOREDELETE"), 0),
            "status": str(ci_get(te, "SSTATUS", default="")).upper(),
            "state_msg": str(ci_get(te, "STATEMESSAGE", default="")),
            "tags": tags,
            "marked_downloaded": "record:download-completed" in tags,
            "id": tid,
            "title": str(ci_get(te, "STITLE", default="Aufnahme")).strip(),
            "subtitle": str(ci_get(te, "SSUBTITLE", default="")).strip(),
            "episode": str(ci_get(te, "SFOLGE", default="")).strip(),
            "station": str(ci_get(te, "STVSTATIONNAME", default="")).strip(),
            "start": start,
            "end": end,
            "formats": sorted(set(formats), reverse=True),
            "adfree": adfree,
        }

    # --- Download -----------------------------------------------------------
    def download_url(self, tid, fmt, adfree):
        q = urllib.parse.urlencode({"TelecastId": tid, "iFormat": fmt, "bAdFree": "true" if adfree else "false"})
        d = self._json(f"{URL_DL_URL}?{q}")
        if not isinstance(d, dict):
            return None, "keine JSON-Antwort"
        err = ci_get(d, "ERROR")
        url = ci_get(d, "DOWNLOADURL", "SDOWNLOADURL")
        if not url:
            arr = ci_get(d, "ARRVIDEOURL")
            if isinstance(arr, list):
                for v in arr:
                    if isinstance(v, str) and v.startswith("http"):
                        url = v
                        break
        return (url or None), (err or None)

    def delete_recording(self, tid):
        txt = self._req(URL_DELETE, {"lTelecastID": tid})
        return "error" not in txt.lower()

    # --- Programm / Aufnahme programmieren --------------------------------
    _station_token = None

    def station_token(self):
        """Paket-Token (z. B. STVXXL) aus der EPG-Seite; wird für die Suche gebraucht."""
        if self._station_token is None:
            self._station_token = ""
            try:
                html = self._req(URL_EPG_PAGE)
                m = re.search(r'vm\.init\([^)]*"([A-Z0-9]+)"\s*\)', html)
                if m:
                    self._station_token = m.group(1)
            except Exception:  # noqa
                pass
            if not self._station_token:
                self._station_token = "STVXXL"   # Fallback (Wert der Website auch bei XL-Paket)
            log.debug("Station-Token: %s", self._station_token)
        return self._station_token

    def stations(self):
        d = self._json(URL_STATIONS)
        out = []
        for st in (ci_get(d, "ARRSTATIONS") or []):
            sid = to_int(ci_get(st, "ID"))
            if sid:
                out.append({"id": sid, "name": str(ci_get(st, "NAME", default=""))})
        return out

    def categories(self):
        """Genres mit Subgenres (für die Genre-Ansicht)."""
        d = self._json(f"{URL_CATEGORIES}?iFunction=1")
        cats = ci_get(d, "STRTVCATEGORIES") or {}
        out = []
        for cid, c in cats.items():
            cid = to_int(cid)
            if cid == 0:
                continue
            sd = self._json(f"{URL_CATEGORIES}?iFunction=2&iTvCategoryId={cid}")
            subs = ci_get(sd, "STRTVSUBCATEGORIES") or {}
            sub_list = sorted([{"id": to_int(k), "name": str(v)} for k, v in subs.items() if to_int(k) != 0],
                              key=lambda x: x["name"])
            out.append({"id": cid, "name": str(ci_get(c, "SNAME", default="")), "subcategories": sub_list})
        order = {"Film": 0, "Serien": 1, "Shows": 2, "Info": 3, "Sport": 4, "Musik": 5}
        out.sort(key=lambda x: order.get(x["name"], 9))
        return out

    def epg_search(self, text, days=28, title_only=True, page=1, per_page=50, station_id=0, mode=6, category=0, subcategory=0):
        d = self._json(URL_EPG_LIST, {
            "iModus": mode, "iPage": page, "iTvCategoryId": category, "sSearchString": text,
            "iEntriesPerPage": per_page, "iTvSubCategoryId": subcategory, "bIsMemberarea": "true",
            "iDays": days, "iTvStationGroupId": 0, "iActualDayTime": 0,
            "bSearchInTitleOnly": 1 if title_only else 0, "iTvStationId": station_id,
            "sStationToken": self.station_token(),
        })
        if not isinstance(d, dict):
            return [], 0
        out = []
        for t in (ci_get(d, "SortedTelecasts") or []):
            start = parse_stv_date(ci_get(t, "DSTARTDATE"))
            end = parse_stv_date(ci_get(t, "DENDDATE"))
            out.append({
                "id": to_int(ci_get(t, "ITELECASTID")),
                "title": str(ci_get(t, "STITLE", default="")).strip(),
                "subtitle": str(ci_get(t, "SSUBTITLE", default="")).strip(),
                "episode": str(ci_get(t, "SFOLGE", default="")).strip(),
                "station": str(ci_get(t, "STVSTATIONNAME", default="")).strip(),
                "start": start.strftime("%Y-%m-%d %H:%M") if start else "",
                "end": end.strftime("%H:%M") if end else "",
                "category": " » ".join(x for x in (str(ci_get(t, "STVCATEGORYNAME", default="")), str(ci_get(t, "SSUBCATEGORYNAME", default=""))) if x),
                "description": str(ci_get(t, "STHEMA", default="")).strip(),
                "image": str(ci_get(t, "SIMGURL", default="")),
                "station_image": str(ci_get(t, "SSTATIONIMGURL", default="")),
                "station_id": to_int(ci_get(t, "TVSTATIONID")),
                "recorded": bool(ci_get(t, "BEXISTRECORD", default=False)),
                "highlight": bool(ci_get(t, "BISTIPOFDAY", default=False)),
            })
        return out, to_int(ci_get(d, "TotalEntries"))

    def epg_record(self, tid):
        """Aufnahme programmieren. Rückgabe (ok, Meldung)."""
        d = self._json(URL_EPG_RECORD, {"TelecastId": tid, "sRecordLocation": "/STV/M/obj/TVProgCtr/TvProgrammSuche.cfm"})
        msg = str(ci_get(d, "SMESSAGE", default="")) if isinstance(d, dict) else "keine Antwort"
        ok = "angelegt" in msg.lower() or "bereits" in msg.lower()
        return ok, msg

    # --- Channels (Serien-Abos) --------------------------------------------
    def channels(self):
        d = self._json(URL_CH_LIST)
        if not isinstance(d, dict):
            return [], 0, 0
        items = []
        for c in (ci_get(d, "ARRCHANNELITEMS") or []):
            items.append({"id": to_int(ci_get(c, "CHANNELID")), "name": str(ci_get(c, "SNAME", default="")),
                          "type": to_int(ci_get(c, "ICHANNELTYPE")), "count": to_int(ci_get(c, "ICOUNTENTRIES"))})
        return items, to_int(ci_get(d, "IUSEDCHANNELS")), to_int(ci_get(d, "IMAXCHANNELS"))

    def channel_create(self, title=None, telecast_id=None):
        """Serien-Abo anlegen: per Titel (Typ 3) oder per Sendung (Typ 4)."""
        if telecast_id:
            data = {"sTelecastTitle": title or "", "channelTypeId": 4, "telecastId": telecast_id}
        else:
            data = {"sTelecastTitle": title, "channelTypeId": 3}
        d = self._json(URL_CH_CREATE, data)
        ok = bool(find_key_recursive(d, "BISSUCCESSMSG")) if isinstance(d, dict) else False
        msgs = find_key_recursive(d, "ARRCREATECHANNELMESSAGE") if isinstance(d, dict) else None
        msg = ""
        if isinstance(msgs, list) and msgs:
            msg = str(ci_get(msgs[0], "SMESSAGE", default=""))
        elif isinstance(d, dict):
            msg = str(find_key_recursive(d, "SMESSAGE") or "")
        return ok, msg

    def channel_delete(self, channel_id, delete_planned=False):
        q = urllib.parse.urlencode({"channelId": channel_id,
                                    "deleteProgrammedRecords": 1 if delete_planned else 0,
                                    "deleteReadyRecords": 0})
        txt = self._req(f"{URL_CH_DELETE}?{q}")
        return "error" not in txt.lower()

    def planned_recordings(self):
        """Programmierte, noch nicht aufgenommene Sendungen (Archiv, Status 2)."""
        recs, page, total_pages = [], 1, 1
        while page <= total_pages:
            d = self.archive_page(page, state=2)
            if not isinstance(d, dict):
                break
            total_pages = max(1, to_int(find_key_recursive(d, "ITOTALPAGES"), 1))
            for e in (find_key_recursive(d, "ARRVIDEOARCHIVEENTRIES") or []):
                r = self._parse_entry(e)
                if r:
                    recs.append(r)
            page += 1
            if page > 50:
                break
        return recs


# --------------------------------------------------------------------------- #
# Download mit Fortsetzung
# --------------------------------------------------------------------------- #
def verify_mp4(path: Path):
    """Grobe Plausibilitätsprüfung: Datei groß genug und MP4-Kopf vorhanden."""
    try:
        if path.stat().st_size < 1_000_000:
            return False, "Datei kleiner als 1 MB"
        with open(path, "rb") as fh:
            head = fh.read(64)
        if b"ftyp" not in head and b"moov" not in head and b"mdat" not in head:
            return False, "kein MP4-Kopf gefunden (evtl. Fehlerseite statt Video)"
        return True, ""
    except OSError as e:
        return False, str(e)


def download_file(url, dest: Path, user_agent, dry_run=False, url_refresh=None, tid=0):
    """Lädt mit Fortsetzung; bei HTTP-Fehlern bis zu 3 Versuche, ggf. mit frisch geholter URL."""
    last_err = None
    for attempt in range(3):
        try:
            return _download_once(url, dest, user_agent, dry_run, tid)
        except urllib.error.HTTPError as e:
            last_err = e
            log.warning("  HTTP %s beim Download (Versuch %d/3)", e.code, attempt + 1)
            if e.code in (401, 403, 404, 410) and url_refresh:
                new_url = url_refresh()
                if new_url:
                    log.info("  Neuer Download-Link geholt.")
                    url = new_url
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as e:
            last_err = e
            log.warning("  Netzfehler beim Download (%s), Versuch %d/3", e, attempt + 1)
        if STOP.is_set():
            raise KeyboardInterrupt
        time.sleep(10 * (attempt + 1))
    raise last_err or IOError("Download fehlgeschlagen")


def _download_once(url, dest: Path, user_agent, dry_run=False, tid=0):
    part = dest.with_suffix(dest.suffix + ".part")
    have = part.stat().st_size if part.exists() else 0
    if dry_run:
        log.info("  [dry-run] würde laden: %s", dest.name)
        return True
    req = urllib.request.Request(url, headers={"User-Agent": user_agent})
    if have:
        req.add_header("Range", f"bytes={have}-")
    with urllib.request.urlopen(req, timeout=120) as resp:
        status = resp.status
        total = resp.headers.get("Content-Length")
        if have and status != 206:            # Server ignoriert Range -> von vorn
            have = 0
        total = (to_int(total) + have) if total else None
        mode = "ab" if have else "wb"
        done = have
        last = time.time()
        t0 = time.time()
        start_bytes = have
        with open(part, mode) as fh:
            while True:
                if STOP.is_set():
                    raise KeyboardInterrupt
                chunk = resp.read(1024 * 512)
                if not chunk:
                    break
                fh.write(chunk)
                done += len(chunk)
                if time.time() - last > 3:
                    pct = (done * 100 // total) if total else -1
                    log.info("  … %s%s", human_size(done), f" ({pct} %)" if pct >= 0 else "")
                    print(f"PROGRESS {pct} {done} {total or 0} {int((done - start_bytes) / max(time.time() - t0, 0.1))} {tid}", flush=True)
                    last = time.time()
    if total and done < total:
        raise IOError(f"Download unvollständig ({human_size(done)} von {human_size(total)})")
    ok, why = verify_mp4(part)
    if not ok:
        part.unlink(missing_ok=True)
        raise IOError(f"Datei verworfen: {why}")
    part.rename(dest)
    log.info("  Fertig: %s (%s)", dest.name, human_size(done))
    return True


def build_filename(cfg, r, fmt, adfree):
    date = r["start"].strftime("%Y-%m-%d") if r["start"] else "0000-00-00"
    name = cfg["filename_pattern"].format(
        date=date,
        title=r["title"],
        subtitle=f" - {r['subtitle']}" if r["subtitle"] and r["subtitle"] != r["title"] else "",
        episode=f" ({r['episode']})" if r["episode"] else "",
        station=r["station"] or "Save.TV",
        format=FORMAT_NAMES.get(fmt, str(fmt)),
        adfree="(werbefrei)" if adfree else "(mit Werbung)",
        id=r["id"],
    )
    return safe_filename(name) + ".mp4"


def quiet_mode(args):
    return bool(args.json or args.check_login or args.selftest or args.epg_search is not None or args.epg or args.categories or args.stations
                or args.record or args.planned or args.cancel or args.channels or args.channel_add
                or args.channel_add_telecast or args.channel_delete)


def selftest(client):
    """Diagnose aller Bausteine; Ausgabe als JSON."""
    res = {"version": VERSION, "python": sys.version.split()[0], "checks": []}
    def check(name, fn):
        t = time.time()
        try:
            v = fn()
            res["checks"].append({"name": name, "ok": True, "detail": str(v)[:200], "ms": int((time.time() - t) * 1000)})
        except Exception as e:  # noqa
            res["checks"].append({"name": name, "ok": False, "detail": f"{type(e).__name__}: {e}"[:300], "ms": int((time.time() - t) * 1000)})
    check("Login", lambda: "ok" if client.login() else (_ for _ in ()).throw(RuntimeError("Anmeldung fehlgeschlagen")))
    check("Paket-Token", lambda: client.station_token() or (_ for _ in ()).throw(RuntimeError("kein Token")))
    check("Archiv (fertig)", lambda: f"{len(client.list_recordings())} Einträge")
    check("Geplante Aufnahmen", lambda: f"{len(client.planned_recordings())} Einträge")
    check("Programm 20:15", lambda: f"{client.epg_search('', days=0, mode=3, per_page=5)[1]} Sendungen")
    check("Programmsuche", lambda: f"{client.epg_search('Tagesschau', days=7, per_page=5)[1]} Treffer")
    check("Genres", lambda: f"{len(client.categories())} Genres")
    check("Abos", lambda: f"{client.channels()[1]}/{client.channels()[2]} belegt")
    target = Path(client.cfg["target_dir"]).expanduser()
    check("Zielordner beschreibbar", lambda: (target.mkdir(parents=True, exist_ok=True), (target / ".write-test").write_text("x"),
                                              (target / ".write-test").unlink(), str(target))[-1])
    res["ok"] = all(c["ok"] for c in res["checks"])
    print(json.dumps(res, ensure_ascii=False))
    return 0 if res["ok"] else 1


# --------------------------------------------------------------------------- #
# Metadaten in die MP4 schreiben
# --------------------------------------------------------------------------- #
def find_tool(name):
    for d in ("/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"):
        p = Path(d) / name
        if p.exists():
            return str(p)
    return shutil.which(name)


def write_metadata(path: Path, r):
    """Schreibt Titel, Serie, Folge, Beschreibung, Sender, Jahr. AtomicParsley bevorzugt, sonst ffmpeg."""
    title = r["title"] + (f" – {r['subtitle']}" if r["subtitle"] and r["subtitle"] != r["title"] else "")
    year = r["start"].strftime("%Y") if r["start"] else ""
    desc = (r.get("description") or "")[:1000]
    ap = find_tool("AtomicParsley")
    if ap:
        cmd = [ap, str(path), "--overWrite", "--title", title, "--TVShowName", r["title"],
               "--TVNetwork", r["station"], "--stik", "TV Show"]
        if r["episode"]:
            cmd += ["--TVEpisode", r["episode"]]
            m = re.search(r"S(\d+)E(\d+)", r["episode"], re.I)
            if m:
                cmd += ["--TVSeasonNum", str(int(m.group(1))), "--TVEpisodeNum", str(int(m.group(2)))]
        if year:
            cmd += ["--year", year]
        if desc:
            cmd += ["--description", desc[:255], "--longdesc", desc]
        res = subprocess.run(cmd, capture_output=True, text=True)
        return res.returncode == 0, "AtomicParsley"
    ff = find_tool("ffmpeg")
    if ff:
        tmp = path.with_suffix(".meta.mp4")
        cmd = [ff, "-y", "-loglevel", "error", "-i", str(path), "-c", "copy", "-movflags", "+faststart",
               "-metadata", f"title={title}", "-metadata", f"show={r['title']}", "-metadata", f"network={r['station']}",
               "-metadata", f"description={desc}", "-metadata", f"date={year}"]
        if r["episode"]:
            cmd += ["-metadata", f"episode_id={r['episode']}"]
        cmd.append(str(tmp))
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode == 0 and tmp.exists() and tmp.stat().st_size > path.stat().st_size * 0.95:
            tmp.replace(path)
            return True, "ffmpeg"
        tmp.unlink(missing_ok=True)
        return False, "ffmpeg"
    return False, "kein Werkzeug (AtomicParsley/ffmpeg) gefunden"


# --------------------------------------------------------------------------- #
# Lokales Aufräumen
# --------------------------------------------------------------------------- #
def cleanup_local(cfg, state):
    """Löscht lokale Aufnahmen nach Alter (cleanup_days) oder wenn zu wenig Platz (cleanup_min_free_gb)."""
    days = to_int(cfg.get("cleanup_days"), 0)
    min_free = float(cfg.get("cleanup_min_free_gb") or 0)
    if days <= 0 and min_free <= 0:
        return 0
    target = Path(cfg["target_dir"]).expanduser()
    if not target.exists():
        return 0
    files = sorted([f for f in target.glob("*.mp4") if f.is_file()], key=lambda f: f.stat().st_mtime)
    removed = 0
    now = time.time()
    if days > 0:
        for f in list(files):
            if now - f.stat().st_mtime > days * 86400:
                log.info("Aufräumen: lösche %s (älter als %d Tage)", f.name, days)
                f.unlink(missing_ok=True); files.remove(f); removed += 1
    if min_free > 0:
        def free_gb():
            st = os.statvfs(str(target)); return st.f_bavail * st.f_frsize / 1e9
        while files and free_gb() < min_free:
            f = files.pop(0)
            log.info("Aufräumen: lösche %s (nur %.1f GB frei)", f.name, free_gb())
            f.unlink(missing_ok=True); removed += 1
    if removed:
        log.info("Aufräumen: %d Datei(en) gelöscht.", removed)
    return removed


# --------------------------------------------------------------------------- #
# Hauptprogramm
# --------------------------------------------------------------------------- #
def load_state():
    if STATE_FILE.exists():
        with open(STATE_FILE, encoding="utf-8") as fh:
            return json.load(fh)
    return {"done": {}, "failed": {}}


def save_state(state):
    tmp = STATE_FILE.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=1, ensure_ascii=False)
    tmp.replace(STATE_FILE)


def setup_logging(verbose, quiet=False):
    CONF_DIR.mkdir(parents=True, exist_ok=True)
    fmt = logging.Formatter("%(asctime)s %(levelname)-7s %(message)s", "%Y-%m-%d %H:%M:%S")
    log.setLevel(logging.DEBUG if verbose else logging.INFO)
    sh = logging.StreamHandler(sys.stderr if quiet else sys.stdout)
    sh.setFormatter(fmt)
    log.addHandler(sh)
    fh = logging.FileHandler(LOG_FILE, encoding="utf-8")
    fh.setFormatter(fmt)
    log.addHandler(fh)
    # Log klein halten
    try:
        if LOG_FILE.stat().st_size > 2_000_000:
            LOG_FILE.replace(LOG_FILE.with_suffix(".log.1"))
    except FileNotFoundError:
        pass


def acquire_lock():
    CONF_DIR.mkdir(parents=True, exist_ok=True)
    if LOCK_FILE.exists():
        try:
            pid = int(LOCK_FILE.read_text().strip())
            os.kill(pid, 0)
            return False                     # Prozess läuft noch
        except (ValueError, ProcessLookupError, PermissionError):
            pass
    LOCK_FILE.write_text(str(os.getpid()))
    return True


def release_lock():
    try:
        LOCK_FILE.unlink()
    except FileNotFoundError:
        pass


def main():
    ap = argparse.ArgumentParser(description="Save.TV Aufnahmen automatisch herunterladen")
    ap.add_argument("--setup", action="store_true", help="Konfiguration interaktiv anlegen")
    ap.add_argument("--list", action="store_true", help="Archiv nur auflisten")
    ap.add_argument("--json", action="store_true", help="Archiv als JSON ausgeben (für die App)")
    ap.add_argument("--check-login", action="store_true", help="nur Login prüfen (Exit 0 = ok)")
    ap.add_argument("--epg-search", metavar="TEXT", help="TV-Programm durchsuchen (JSON)")
    ap.add_argument("--days", type=int, default=28, help="Zeitraum für --epg-search in Tagen (Standard 28)")
    ap.add_argument("--epg", choices=list(EPG_MODES.keys()), help="Programmübersicht: now, next, prime (20:15), late (22:15), highlights (JSON)")
    ap.add_argument("--category", type=int, default=0, help="Genre-ID für --epg genre")
    ap.add_argument("--subcategory", type=int, default=0, help="Subgenre-ID für --epg genre")
    ap.add_argument("--categories", action="store_true", help="Genres und Subgenres auflisten (JSON)")
    ap.add_argument("--stations", action="store_true", help="Sender auflisten (JSON)")
    ap.add_argument("--station", type=int, default=0, help="Sender-ID als Filter für --epg/--epg-search")
    ap.add_argument("--page", type=int, default=1)
    ap.add_argument("--per-page", type=int, default=60)
    ap.add_argument("--channels", action="store_true", help="Serien-Abos (Channels) auflisten (JSON)")
    ap.add_argument("--channel-add", metavar="TITEL", help="Serien-Abo per Titel anlegen (JSON)")
    ap.add_argument("--channel-add-telecast", type=int, metavar="ID", help="Serien-Abo aus einer Sendung anlegen (JSON)")
    ap.add_argument("--channel-delete", type=int, metavar="CHANNELID", help="Serien-Abo löschen (JSON)")
    ap.add_argument("--delete-planned", action="store_true", help="mit --channel-delete: auch programmierte Aufnahmen löschen")
    ap.add_argument("--cleanup", action="store_true", help="lokale Aufräumregeln anwenden und beenden")
    ap.add_argument("--selftest", action="store_true", help="Diagnose: Login, Archiv, Programm, Token (JSON)")
    ap.add_argument("--all-text", action="store_true", help="--epg-search auch in Beschreibungen suchen")
    ap.add_argument("--record", type=int, action="append", metavar="ID", help="Sendung(en) zur Aufnahme programmieren (JSON)")
    ap.add_argument("--planned", action="store_true", help="programmierte Aufnahmen auflisten (JSON)")
    ap.add_argument("--cancel", type=int, action="append", metavar="ID", help="programmierte Aufnahme(n) löschen (JSON)")
    ap.add_argument("--dry-run", action="store_true", help="nichts herunterladen, nur anzeigen")
    ap.add_argument("--dump", action="store_true", help="Roh-JSON in ~/.savetv-dl/ speichern (Fehlersuche)")
    ap.add_argument("--retry-failed", action="store_true", help="fehlgeschlagene Downloads erneut versuchen")
    ap.add_argument("--id", type=int, action="append", help="nur diese Telecast-ID(s) laden (erzwingt Download)")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    if args.setup:
        setup_interactive()
        return 0

    quiet = bool(args.json or args.check_login or args.selftest or args.epg_search is not None or args.epg or args.categories or args.stations or args.record or args.planned
                 or args.cancel or args.channels or args.channel_add or args.channel_add_telecast or args.channel_delete)
    setup_logging(args.verbose, quiet=quiet)
    cfg = load_config()
    read_only = quiet or args.list or args.dry_run
    if not read_only and not acquire_lock():
        log.info("Läuft bereits – Abbruch.")
        return 0
    try:
        return run(cfg, args)
    except Exception as e:  # noqa
        log.error("Abbruch: %s", e, exc_info=args.verbose)
        if quiet:
            print(json.dumps({"error": "exception", "message": f"{type(e).__name__}: {e}"}, ensure_ascii=False))
        return 2
    finally:
        if not read_only:
            release_lock()


def run(cfg, args):
    client = StvClient(cfg)
    if args.selftest:
        return selftest(client)
    if not client.login():
        if quiet_mode(args):
            print(json.dumps({"error": "login", "message": "Anmeldung bei Save.TV fehlgeschlagen"}))
        return 1
    if args.check_login:
        print("OK")
        return 0

    if args.epg_search is not None:
        items, total = client.epg_search(args.epg_search, days=args.days, title_only=not args.all_text,
                                         page=args.page, per_page=args.per_page, station_id=args.station)
        print(json.dumps({"results": items, "total": total}, ensure_ascii=False))
        return 0
    if args.categories:
        print(json.dumps({"categories": client.categories()}, ensure_ascii=False))
        return 0
    if args.stations:
        print(json.dumps({"stations": client.stations()}, ensure_ascii=False))
        return 0
    if args.epg:
        items, total = client.epg_search("", days=(args.days if args.epg == "genre" else 0), mode=EPG_MODES[args.epg],
                                         category=args.category, subcategory=args.subcategory,
                                         page=args.page, per_page=args.per_page, station_id=args.station)
        print(json.dumps({"results": items, "total": total}, ensure_ascii=False))
        return 0
    if args.channels:
        items, used, mx = client.channels()
        print(json.dumps({"channels": items, "used": used, "max": mx}, ensure_ascii=False))
        return 0
    if args.channel_add or args.channel_add_telecast:
        ok, msg = client.channel_create(title=args.channel_add, telecast_id=args.channel_add_telecast)
        log.info("Channel anlegen: %s – %s", ok, msg)
        print(json.dumps({"ok": ok, "message": msg}, ensure_ascii=False))
        return 0 if ok else 1
    if args.channel_delete:
        ok = client.channel_delete(args.channel_delete, args.delete_planned)
        log.info("Channel %s gelöscht: %s", args.channel_delete, ok)
        print(json.dumps({"ok": ok}))
        return 0 if ok else 1
    if args.cleanup:
        cleanup_local(cfg, load_state())
        return 0
    if args.record:
        res = []
        for tid in args.record:
            ok, msg = client.epg_record(tid)
            res.append({"id": tid, "ok": ok, "message": msg})
            log.info("Aufnahme %s: %s", tid, msg)
        print(json.dumps({"results": res}, ensure_ascii=False))
        return 0
    if args.cancel:
        res = []
        for tid in args.cancel:
            ok = client.delete_recording(tid)
            res.append({"id": tid, "ok": ok})
            log.info("Aufnahme %s gelöscht: %s", tid, ok)
        print(json.dumps({"results": res}, ensure_ascii=False))
        return 0
    if args.planned:
        out = []
        for r in client.planned_recordings():
            out.append({"id": r["id"], "title": r["title"], "subtitle": r["subtitle"], "episode": r["episode"],
                        "station": r["station"], "start": r["start"].strftime("%Y-%m-%d %H:%M") if r["start"] else "",
                        "end": r["end"].strftime("%H:%M") if r["end"] else "", "state_msg": r["state_msg"]})
        print(json.dumps({"planned": out}, ensure_ascii=False))
        return 0

    recs = client.list_recordings(dump=args.dump)
    log.info("%d Aufnahmen im Archiv.", len(recs))
    state = load_state()
    if args.retry_failed:
        state["failed"] = {}

    if args.json:
        out = []
        for r in recs:
            tid = str(r["id"])
            out.append({
                "id": r["id"], "title": r["title"], "subtitle": r["subtitle"], "episode": r["episode"],
                "station": r["station"],
                "start": r["start"].strftime("%Y-%m-%d %H:%M") if r["start"] else "",
                "status": r["status"], "state_msg": r["state_msg"], "adfree": r["adfree"],
                "formats": [FORMAT_NAMES.get(f, str(f)) for f in r["formats"]],
                "marked_downloaded": r["marked_downloaded"],
                "image": r["image"], "station_image": r["station_image"], "days_left": r["days_left"],
                "done": tid in state["done"],
                "file": (state["done"].get(tid) or {}).get("file"),
                "failed": (state["failed"].get(tid) or {}).get("error"),
            })
        print(json.dumps({"records": out, "count": len(out)}, ensure_ascii=False))
        return 0

    if args.list:
        for r in recs:
            mark = "✓" if str(r["id"]) in state["done"] else ("s" if r["marked_downloaded"] else " ")
            fmts = "/".join(FORMAT_NAMES.get(f, str(f)) for f in r["formats"]) or "-"
            st = r["start"].strftime("%d.%m.%Y %H:%M") if r["start"] else "?"
            print(f"{mark} {r['id']:>9}  {st}  {r['station']:<12.12} {fmts:<10} "
                  f"{'werbefrei' if r['adfree'] else '':<9} {r['title']} {r['subtitle']}")
        return 0

    target = Path(cfg["target_dir"]).expanduser()
    target.mkdir(parents=True, exist_ok=True)
    prio = [FORMAT_IDS.get(str(f).lower(), to_int(f)) for f in cfg["format_priority"]]
    now = datetime.now()
    count = 0
    jobs = []

    for r in recs:
        tid = str(r["id"])
        forced = bool(args.id)
        if forced and r["id"] not in args.id:
            continue
        if not forced and tid in state["done"]:
            continue
        if not forced and tid in state["failed"] and state["failed"][tid].get("count", 0) >= 5:
            continue
        if not r["formats"] or (r["status"] and r["status"] != "OK"):
            log.debug("Noch nicht fertig: %s (%s) – %s", tid, r["title"], r["state_msg"])
            continue
        if not forced and cfg.get("skip_marked_downloaded") and r["marked_downloaded"]:
            log.info("Übersprungen (bei Save.TV bereits als heruntergeladen markiert): %s – ID %s",
                     r["title"], tid)
            state["done"][tid] = {"file": None, "date": now.isoformat(timespec="seconds"),
                                  "note": "bereits bei Save.TV als heruntergeladen markiert"}
            save_state(state)
            continue
        if not forced and r["end"] and (now - r["end"]).total_seconds() < cfg["min_age_minutes"] * 60:
            log.debug("Aufnahme %s zu frisch, warte.", tid)
            continue
        if not forced and count >= cfg["max_downloads_per_run"]:
            log.info("Limit von %d Downloads pro Lauf erreicht.", cfg["max_downloads_per_run"])
            break

        fmt = next((f for f in prio if f in r["formats"]), r["formats"][0])
        adfree = bool(cfg["adfree"] and r["adfree"])
        if not forced and cfg.get("adfree_only") and cfg["adfree"] and not r["adfree"]:
            log.info("Warte auf Schnittliste (noch nicht werbefrei): %s – ID %s", r["title"], tid)
            continue
        jobs.append((r, fmt, adfree))
        count += 1

    # --- Downloads (parallel) -------------------------------------------------
    state_lock = threading.Lock()

    def fail(tid, msg):
        with state_lock:
            f = state["failed"].setdefault(tid, {"count": 0})
            f["count"] += 1
            f["last"] = now.isoformat(timespec="seconds")
            f["error"] = msg
            save_state(state)

    def job(r, fmt, adfree):
        tid = str(r["id"])
        label = f"{r['title']} {r['subtitle']}".strip()
        log.info("Lade %s [%s, %s] – ID %s", label, FORMAT_NAMES.get(fmt, fmt),
                 "werbefrei" if adfree else "mit Werbung", tid)
        print(f"START {tid} {label}", flush=True)
        url, err = client.download_url(r["id"], fmt, adfree)
        if not url and adfree:
            if cfg.get("adfree_only"):
                log.warning("  Werbefreier Link nicht verfügbar (%s) – später erneut.", err or "?")
                fail(tid, "werbefrei nicht verfügbar: " + (err or "?"))
                return False
            log.warning("  Werbefreie Version nicht verfügbar (%s) – lade ungeschnitten.", err or "?")
            adfree = False
            url, err = client.download_url(r["id"], fmt, False)
        if not url:
            log.error("  Kein Download-Link: %s", err or "unbekannter Fehler")
            fail(tid, err or "kein Link")
            return False
        dest = target / build_filename(cfg, r, fmt, adfree)
        if dest.exists() and not args.dry_run:
            log.info("  Datei existiert bereits, markiere als erledigt.")
        else:
            try:
                download_file(url, dest, cfg["user_agent"], dry_run=args.dry_run,
                              url_refresh=lambda: client.download_url(r["id"], fmt, adfree)[0], tid=r["id"])
            except Exception as e:  # noqa
                log.error("  Download fehlgeschlagen: %s", e)
                fail(tid, str(e))
                return False
        if args.dry_run:
            return True
        if cfg.get("write_metadata"):
            try:
                ok, tool = write_metadata(dest, r)
                log.info("  Metadaten %s (%s).", "geschrieben" if ok else "nicht geschrieben", tool)
            except Exception as e:  # noqa
                log.warning("  Metadaten fehlgeschlagen: %s", e)
        with state_lock:
            state["done"][tid] = {"file": dest.name, "date": now.isoformat(timespec="seconds")}
            state["failed"].pop(tid, None)
            save_state(state)
        if cfg["delete_after_download"]:
            if client.delete_recording(r["id"]):
                log.info("  Bei Save.TV gelöscht.")
            else:
                log.warning("  Löschen bei Save.TV fehlgeschlagen.")
        print(f"DONE {tid}", flush=True)
        return True

    ok_count = 0
    workers = max(1, min(3, to_int(cfg.get("parallel_downloads"), 2)))
    if jobs:
        log.info("%d Download(s), %d parallel.", len(jobs), workers)
    ex = ThreadPoolExecutor(max_workers=workers)
    futures = [ex.submit(job, r, fmt, adfree) for (r, fmt, adfree) in jobs]
    try:
        for fu in as_completed(futures):
            try:
                if fu.result():
                    ok_count += 1
            except KeyboardInterrupt:
                raise
            except Exception as e:  # noqa
                log.error("Download-Job abgebrochen: %s", e)
    finally:
        ex.shutdown(wait=True, cancel_futures=True)
    count = ok_count
    if STOP.is_set():
        log.info("Abgebrochen – %d Download(s) fertig, Rest wird beim nächsten Lauf fortgesetzt.", count)
        return 130

    try:
        cleanup_local(cfg, state)
    except Exception as e:  # noqa
        log.warning("Aufräumen fehlgeschlagen: %s", e)
    log.info("Lauf beendet: %d Download(s).", count)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        release_lock()
        sys.exit(130)
