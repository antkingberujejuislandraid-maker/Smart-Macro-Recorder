;===============================================================================
;  SMART MACRO RECORDER & PLAYER  —  AutoHotkey v2
;===============================================================================
;  FEATURES
;    • Record mouse clicks and/or keystrokes with exact time delays
;    • GUI toggles, playback speed multiplier, loop count (0=infinite)
;    • Save / load macros to a *.macro file (JSON, hand-editable)
;    • Image recognition gates during playback, per-image actions
;    • HITBOX ZONE MANAGER: named screen regions with click / scroll /
;      hover actions, loop / image-match / hotkey triggers, drag-capture,
;      and image searches restricted to a zone for speed & accuracy
;    • Play/Pause hotkey, emergency kill switch, status overlays
;
;  QUICK START
;    1. F8 record, F8 stop.  F9 play/pause.  F12 = panic.
;    2. "Hitbox Zone Manager" button: New zone -> drag a region ->
;       pick an action + trigger -> Save zone. Zones persist in
;       hitboxes.json and are re-applied automatically on next start.
;===============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Force
SendMode "Input"

; [REQ 5] One consistent coordinate system for mouse, pixels and tooltips
CoordMode("Mouse", "Screen")
CoordMode("Pixel", "Screen")
CoordMode("ToolTip", "Screen")

; DPI awareness so ImageSearch / zones stay accurate on scaled displays
try DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")

;===============================================================================
;  CONFIG — HOTKEYS (customizable)
;===============================================================================
HK_RECORD := "F8"       ; start / stop recording
HK_PLAY   := "F9"       ; play / pause playback
HK_KILL   := "F12"      ; emergency kill switch
KILL_MODE := "Reload"   ; "Reload" = stop everything & restart (recommended)
                        ; "Stop"   = just halt playback/recording, keep script

;===============================================================================
;  CONFIG — IMAGE RECOGNITION RULES
;===============================================================================
;  HOW TO ADD YOUR OWN REFERENCE IMAGES
;  ----------------------------------------------------------------------------
;  1. Drop screenshot crops into the "images" folder next to this script
;     (created automatically). PNG and BMP work best.
;  2. Add one ImageRule(...) line to the array below, e.g.:
;        ImageRule("My Button", "images\button.png", "Click", "Ignore", 40)
;  3. Actions:
;        ActionIfFound    -> "Click" (click match center) | "Ignore" | "StopMacro"
;        ActionIfNotFound -> same options ("Click" is treated as "Ignore")
;  4. Tolerance (0-255): allowed per-pixel color variation. 30-60 is typical.
;  5. Region "x1,y1,x2,y2": limits the search ("" = whole primary screen).
;  6. NEW — Zone: name of a Hitbox Zone (see the Zone Manager). If the zone
;     exists, the image is searched ONLY inside that zone — much faster and
;     far fewer false positives than a full-screen scan. If the zone name
;     doesn't exist, the rule falls back to Region / full screen.
;===============================================================================
class ImageRule {
    __New(name, path, actionIfFound := "Ignore", actionIfNotFound := "Ignore",
          tolerance := 40, region := "", notify := true, zone := "") {
        this.Name             := name
        this.Path             := path
        this.ActionIfFound    := actionIfFound
        this.ActionIfNotFound := actionIfNotFound
        this.Tolerance        := tolerance   ; 0-255 color variation allowed
        this.Region           := region      ; "x1,y1,x2,y2" or "" = full screen
        this.Notify           := notify      ; show "Image Found!" tooltips
        this.Zone             := zone        ; Hitbox Zone name -> search only there
        this.W := 0, this.H := 0             ; image size, cached (for center clicks)
        this.Warned           := false       ; "file missing" warning shown once
    }
}

;   Name            File                        If FOUND    If NOT      Tol  Region         Zone
g_ImageRules := [
    ImageRule("Start Button", "images\start_button.png", "Click",     "Ignore",    40),
    ImageRule("Error Popup",  "images\error_popup.bmp",  "StopMacro", "Ignore",    30),
    ImageRule("Save Prompt",  "images\save_prompt.png",  "Ignore",    "StopMacro", 50, "0,0,960,540"),
    ImageRule("Toolbar Icon", "images\toolbar_icon.png", "Click",     "Ignore",    45, "", true, "Toolbar")
]

; Mouse buttons captured while recording
MOUSE_BTNS := ["LButton", "RButton", "MButton", "XButton1", "XButton2"]

; Playback tuning
g_ImgCheckEveryN := 1      ; run image checks before every Nth action
g_InterLoopDelay := 300    ; ms pause between loop repetitions
g_StartDelay     := 300    ; ms lead-in before playback starts
g_InterZoneDelay := 120    ; ms pause before each hitbox action during playback

;===============================================================================
;  HITBOX ZONES — dynamic target regions
;===============================================================================
;  A zone = a named rectangle on screen + one action + one auto-trigger
;  (plus an optional always-on hotkey). Managed via the Zone Manager GUI,
;  persisted to hitboxes.json next to the script.
;===============================================================================
class HitboxZone {
    __New(name := "New Zone", x1 := 0, y1 := 0, x2 := 0, y2 := 0) {
        this.Name := name
        this.X1 := x1, this.Y1 := y1, this.X2 := x2, this.Y2 := y2
        this.Action        := "Click Left"   ; see ZONE_ACTIONS below
        this.ScrollNotches := 3              ; wheel notches (scroll actions)
        this.AutoTrigger   := "None"         ; None | Every N Loops | On Image Match
        this.EveryN        := 1              ; for "Every N Loops"
        this.LinkedImage   := ""             ; ImageRule name, for "On Image Match"
        this.Hotkey        := ""             ; e.g. "^!z" — fires ANY time (if enabled)
        this.Enabled       := true
    }
    CenterX() => (this.X1 + this.X2) // 2
    CenterY() => (this.Y1 + this.Y2) // 2
    RegionStr() => this.X1 "," this.Y1 " – " this.X2 "," this.Y2
}

; Dropdown contents (exact strings — used by the editor and ExecuteZone)
ZONE_ACTIONS  := ["Click Left", "Click Right", "Double Click", "Random Left Click",
                  "Random Right Click", "Scroll Up", "Scroll Down", "Hover / Move"]
ZONE_TRIGGERS := ["None", "Every N Loops", "On Image Match"]
ZONE_FILE     := A_ScriptDir "\hitboxes.json"

;===============================================================================
;  RUNTIME STATE
;===============================================================================
S := {}
S.Recording      := false
S.Playing        := false
S.Paused         := false
S.StopRequested  := false
S.Actions        := []        ; the macro: array of {type, delay, ...} objects
S.LastTick       := 0
S.HeldKeys       := Map()     ; keys currently down (filters OS auto-repeat)
S.InputHook      := 0
S.Gui            := 0
S.MgrShown       := false     ; was the Zone Manager visible before record/play?
S.RecordMouse    := true
S.RecordKeyboard := true
S.ImageRec       := true
S.Speed          := 1.0
S.Loops          := 1

g_HitboxZones   := []         ; array of HitboxZone
g_ZoneHotkeys   := []         ; hotkey strings currently registered for zones
g_ZoneEditing   := 0          ; zone being edited in the manager (0 = new)
ZONE_MGR        := 0          ; Zone Manager Gui (kept alive, hidden on close)
g_RegionCapture := 0          ; active drag-capture overlay state
g_HKCapture     := 0          ; active hotkey-capture InputHook state

;===============================================================================
;  STARTUP
;===============================================================================
try DirCreate(A_ScriptDir "\images")

BuildGui()
RegisterHotkeys()
LoadZones()                       ; restore hitboxes.json if present
ApplyZoneHotkeys()                ; register any zone hotkeys

A_IconTip := "Smart Macro Recorder`n" HK_RECORD " record | " HK_PLAY " play/pause | " HK_KILL " kill switch"

zoneNote := (g_HitboxZones.Length > 0) ? "   |   " g_HitboxZones.Length " hitbox zone(s) loaded" : ""
miss := CheckImageFiles()
if (miss = "")
    ShowStatus("Ready.  " HK_RECORD " = record,  " HK_PLAY " = play/pause,  " HK_KILL " = emergency stop." zoneNote, 6000)
else
    ShowStatus("Image files not found (see g_ImageRules):`n" miss, 6000)

;===============================================================================
;  MAIN GUI
;===============================================================================
BuildGui() {
    global S, g_ImageRules

    g := Gui(, "Smart Macro Recorder — AHK v2")
    g.SetFont("s10", "Segoe UI")

    ; ---- recording options ----
    g.Add("GroupBox", "x10 y8 w310 h96", " Recording options ")
    g.Add("CheckBox", "x22 y32 w140 vRecordMouse Checked", "Record mouse")
    g.Add("CheckBox", "x168 y32 w146 vRecordKeyboard Checked", "Record keyboard")
    g.Add("CheckBox", "x22 y58 w290 vImageRec Checked", "Enable image recognition (playback)")

    ; ---- playback settings ----
    g.Add("GroupBox", "x10 y112 w310 h64", " Playback settings ")
    g.Add("Text", "x22 y136 w44",  "Speed:")
    g.Add("Edit", "x70 y132 w54 vSpeedMultiplier", "1.0")       ; 2.0 = twice as fast
    g.Add("Text", "x136 y136 w118", "Loops (0 = infinite):")
    g.Add("Edit", "x258 y132 w50 vLoopCount", "1")              ; 0 = infinite

    ; ---- image recognition rules (read-only view of the config above) ----
    g.Add("GroupBox", "x10 y184 w310 h150", " Image recognition rules (edit in script) ")
    lv := g.Add("ListView", "x22 y204 w296 h96", ["Rule", "Image file", "If found", "If not found", "Tol"])
    for i, rule in g_ImageRules
        lv.Add("", rule.Name, rule.Path, rule.ActionIfFound, rule.ActionIfNotFound, rule.Tolerance)
    lv.ModifyCol(1, 58), lv.ModifyCol(2, 96), lv.ModifyCol(3, 62), lv.ModifyCol(4, 62), lv.ModifyCol(5, 28)
    g.Add("Text", "x22 y306 w296 h22", "Add rules in g_ImageRules — link each to a Hitbox Zone for faster searching.")

    ; ---- buttons ----
    g.Add("Button", "x10 y342 w150",  "Save macro to file").OnEvent("Click", SaveMacroToFile)
    g.Add("Button", "x170 y342 w150", "Load macro from file").OnEvent("Click", LoadMacroFromFile)
    g.Add("Button", "x10 y374 w150",  "Stop playback").OnEvent("Click", StopPlayback)
    g.Add("Button", "x170 y374 w150", "Test image search").OnEvent("Click", TestImageSearch)
    g.Add("Button", "x10 y406 w310",  "Hitbox Zone Manager...").OnEvent("Click", OpenZoneManager)

    ; ---- status line ----
    g.Add("Text", "x10 y438 w310 h40 vStatusText", "Idle.")

    g.OnEvent("Close",   (*) => ExitApp())
    g.OnEvent("Escape",  (*) => g.Hide())     ; Esc hides the window (tray > Show window)
    g.Show()
    S.Gui := g
}

RegisterHotkeys() {
    global HK_RECORD, HK_PLAY, HK_KILL, MOUSE_BTNS

    for i, spec in [[HK_RECORD, ToggleRecording], [HK_PLAY, TogglePlayback], [HK_KILL, EmergencyStop]] {
        try Hotkey(spec[1], spec[2])
        catch as e
            MsgBox("Could not register hotkey '" spec[1] "':`n" e.Message, "Startup error", "Icon!")
    }

    ; mouse-capture hotkeys — created DISABLED, switched on only while recording
    for i, btn in MOUSE_BTNS
        Hotkey("~*" btn, OnRecordMouseClick, "Off")

    ; tray conveniences
    A_TrayMenu.Insert("1&", "Show window", ShowMainWindow)
    A_TrayMenu.Insert("2&", "Hitbox Zone Manager", OpenZoneManager)
    A_TrayMenu.Insert("3&", "Emergency stop / reload", (*) => Reload())
    A_TrayMenu.Default := "Show window"
}

ShowMainWindow(*) {
    global S
    if IsObject(S.Gui)
        S.Gui.Show()
}

;===============================================================================
;  RECORDING
;===============================================================================
ToggleRecording(*) {
    global S
    if (S.Playing) {
        ShowStatus("Cannot record while a macro is playing — stop it first.", 2500)
        return
    }
    if (S.Recording)
        StopRecording()
    else
        StartRecording()
}

StartRecording() {
    global S, HK_RECORD, ZONE_MGR, g_RegionCapture, g_HKCapture
    ReadGuiSettings()
    if (!S.RecordMouse && !S.RecordKeyboard) {
        ShowStatus("Enable at least one of 'Record mouse' / 'Record keyboard'.", 3000)
        return
    }
    ; cancel any pending overlays so they can't pollute the recording
    if IsObject(g_RegionCapture)
        EndRegionCapture(false)
    if IsObject(g_HKCapture)
        try g_HKCapture.ih.Stop()

    S.Actions   := []
    S.HeldKeys  := Map()
    S.LastTick  := 0
    S.Recording := true

    ; ---- keyboard: InputHook in pass-through ("V") mode, notify-all ("N") ----
    ih := InputHook("V")
    ih.KeyOpt("{All}", "N")
    ih.OnKeyDown := OnRecKeyDown
    ih.OnKeyUp   := OnRecKeyUp
    ih.Start()
    S.InputHook := ih

    ; ---- mouse: tilde hotkeys ----
    SetMouseHotkeys(true)

    ; keep our windows out of the recording
    if IsObject(S.Gui)
        S.Gui.Minimize()
    S.MgrShown := false
    if IsObject(ZONE_MGR) {
        S.MgrShown := DllCall("IsWindowVisible", "ptr", ZONE_MGR.Hwnd)
        if S.MgrShown
            ZONE_MGR.Hide()
    }
    ShowStatus("Recording...  (press " HK_RECORD " to stop)", 0)
    TrayTip("Recording started", "Smart Macro Recorder")
}

StopRecording() {
    global S, HK_PLAY, ZONE_MGR
    S.Recording := false
    if IsObject(S.InputHook) {
        try S.InputHook.Stop()
        S.InputHook := 0
    }
    S.HeldKeys := Map()
    SetMouseHotkeys(false)
    if IsObject(S.Gui)
        S.Gui.Restore()
    if (S.MgrShown && IsObject(ZONE_MGR))
        ZONE_MGR.Show()
    S.MgrShown := false
    n := S.Actions.Length
    if (n = 0)
        ShowStatus("Recording stopped — nothing was captured.", 4000)
    else
        ShowStatus("Recorded " n " actions.  Press " HK_PLAY " to play.", 4000)
    TrayTip("Recording stopped (" n " actions)", "Smart Macro Recorder")
}

SetMouseHotkeys(enable) {
    global MOUSE_BTNS
    for i, btn in MOUSE_BTNS
        Hotkey("~*" btn, OnRecordMouseClick, enable ? "On" : "Off")
}

OnRecordMouseClick(hkName) {
    global S
    if (!S.Recording || !S.RecordMouse)
        return
    btn := StrReplace(hkName, "~*", "")
    MouseGetPos(&mx, &my)
    RecordEvent({type: "click", x: mx, y: my, button: btn, delay: 0})
}

OnRecKeyDown(ih, vk, sc) {
    global S
    if (!S.Recording || !S.RecordKeyboard)
        return
    key := KeyNameFromHook(vk, sc)
    if (key = "" || IsControlKey(key))       ; never record our own control keys
        return
    if (S.HeldKeys.Has(key))                 ; skip OS auto-repeat floods
        return
    S.HeldKeys[key] := true
    ev := {type: "key", key: key, state: "down", delay: 0}
    if (IsInteger(vk) && vk > 0 && vk < 256)
        ev.vk := Format("{:X}", vk)          ; vk code => bulletproof Send() playback
    RecordEvent(ev)
}

OnRecKeyUp(ih, vk, sc) {
    global S
    if (!S.Recording || !S.RecordKeyboard)
        return
    key := KeyNameFromHook(vk, sc)
    if (!S.HeldKeys.Has(key))
        return
    S.HeldKeys.Delete(key)
    ev := {type: "key", key: key, state: "up", delay: 0}
    if (IsInteger(vk) && vk > 0 && vk < 256)
        ev.vk := Format("{:X}", vk)
    RecordEvent(ev)
}

KeyNameFromHook(p1, p2) {
    if (IsInteger(p1) && IsInteger(p2)) {
        try {
            name := GetKeyName(Format("vk{:X}sc{:X}", p1, p2))
            if (name != "")
                return name
        } catch {
        }
        try {
            name := GetKeyName(Format("vk{:X}", p1))
            if (name != "")
                return name
        } catch {
        }
        return ""
    }
    return String(p1)
}

IsControlKey(keyName) {
    global HK_RECORD, HK_PLAY, HK_KILL, g_HitboxZones
    static ctrl := []
    if (ctrl.Length = 0) {
        for i, hk in [HK_RECORD, HK_PLAY, HK_KILL] {
            k := RegExReplace(hk, "^[#!^+*]+")
            if (k != "")
                ctrl.Push(k)
        }
    }
    for i, k in ctrl
        if (keyName = k)
            return true
    ; zone hotkeys are control keys too — never record them into macros
    for z in g_HitboxZones {
        k := RegExReplace(z.Hotkey, "^[#!^+*~$]+")
        if (k != "" && k = keyName)
            return true
    }
    return false
}

RecordEvent(action) {
    global S
    now := A_TickCount
    action.delay := (S.LastTick = 0) ? 0 : (now - S.LastTick)
    S.LastTick := now
    S.Actions.Push(action)
}

;===============================================================================
;  PLAYBACK
;===============================================================================
TogglePlayback(*) {
    global S, HK_RECORD, HK_PLAY
    if (S.Recording) {
        ShowStatus("Stop recording first (" HK_RECORD ").", 2500)
        return
    }
    if (S.Playing) {
        S.Paused := !S.Paused
        ShowStatus(S.Paused ? "Paused — press " HK_PLAY " to resume" : "Playing...", 0)
        return
    }
    if (S.Actions.Length = 0) {
        ShowStatus("Nothing to play — record (" HK_RECORD ") or load a macro first.", 3000)
        return
    }
    ReadGuiSettings()
    SetTimer(PlayMacro, -1)                  ; playback runs in its own thread
}

PlayMacro() {
    global S, g_ImgCheckEveryN, g_InterLoopDelay, g_StartDelay, HK_KILL, ZONE_MGR

    imgNote := ""
    imgActive := false
    if (S.ImageRec) {
        if (HasUsableImageRule())
            imgActive := true
        else
            imgNote := "   [image files missing — recognition skipped]"
    }
    checkN := Max(1, Round(g_ImgCheckEveryN))

    S.Playing       := true
    S.Paused        := false
    S.StopRequested := false
    heldKeys        := Map()
    total           := S.Actions.Length
    loopTxt := (S.Loops = 0) ? "infinite loops (stop with the Stop button or " HK_KILL ")" : S.Loops " loop(s)"
    ShowStatus("Playing...  " total " actions, " loopTxt ", speed " S.Speed "x" imgNote, 0)
    TrayTip("Playback started", "Smart Macro Recorder")

    if IsObject(S.Gui)
        S.Gui.Minimize()
    mgrShown := false
    if IsObject(ZONE_MGR) {                  ; manager could cover a hitbox — hide it
        mgrShown := DllCall("IsWindowVisible", "ptr", ZONE_MGR.Hwnd)
        if mgrShown
            ZONE_MGR.Hide()
    }
    Sleep(g_StartDelay)

    loopsDone := 0, stopped := false, lastTip := 0
    while (!stopped) {
        for i, action in S.Actions {
            if !WaitDelay(action.delay) {    ; recorded delay, speed-scaled
                stopped := true
                break
            }
            if (imgActive && Mod(i, checkN) = 0) {
                if !RunImageChecks() {       ; image recognition gate
                    stopped := true
                    break
                }
            }
            PerformAction(action, heldKeys)
            if (A_TickCount - lastTip >= 250) {
                lastTip := A_TickCount
                lp := (S.Loops = 0) ? (loopsDone + 1) : (loopsDone + 1) "/" S.Loops
                ShowStatus("Playing...  loop " lp "  |  action " i "/" total, 0)
            }
        }
        if (stopped)
            break
        loopsDone++
        ; ---- hitbox zones with an "Every N loops" trigger fire here ----
        if !RunZoneLoopTriggers(loopsDone) {
            stopped := true
            break
        }
        if (S.Loops > 0 && loopsDone >= S.Loops)
            break
        if !WaitDelay(g_InterLoopDelay)
            break
    }

    ReleaseHeldKeys(heldKeys)
    S.Playing := false
    S.Paused  := false
    if IsObject(S.Gui)
        S.Gui.Restore()
    if (mgrShown && IsObject(ZONE_MGR))
        ZONE_MGR.Show()
    if (stopped)
        ShowStatus("Playback stopped after " loopsDone " loop(s).", 2500)
    else
        ShowStatus("Playback finished: " loopsDone " loop(s) x " total " action(s).", 3500)
    TrayTip("Playback ended", "Smart Macro Recorder")
}

WaitDelay(ms) {
    global S
    while (S.Paused && !S.StopRequested)
        Sleep(40)
    if (S.StopRequested)
        return false
    if (!IsNumber(ms) || ms <= 0)
        return true
    target := A_TickCount + Round(ms / S.Speed)
    loop {
        if (S.StopRequested)
            return false
        if (S.Paused) {
            Sleep(40)
            target += 40                     ; freeze the countdown while paused
            continue
        }
        remaining := target - A_TickCount
        if (remaining <= 0)
            return true
        Sleep(Min(remaining, 25))
    }
}

PerformAction(a, heldKeys) {
    static btnMap := Map("LButton", "Left", "RButton", "Right", "MButton", "Middle",
                         "XButton1", "X1", "XButton2", "X2")
    if (a.type = "click") {
        btn := btnMap.Has(a.button) ? btnMap[a.button] : a.button
        MouseClick(btn, a.x, a.y, 1)
        return
    }
    if (a.type != "key")
        return
    state := (a.state = "up") ? "up" : "down"
    vkHex := ""
    if (a.HasOwnProp("vk") && a.vk != "")
        vkHex := a.vk
    else if (a.key != "") {
        vkInt := 0
        try vkInt := GetKeyVK(a.key)         ; GetKeyVK is the correct v2 function
        if (vkInt > 0)
            vkHex := Format("{:X}", vkInt)
    }
    if (vkHex != "") {
        Send("{blind}{vk" vkHex " " state "}")
        if (state = "down")
            heldKeys[vkHex] := true
        else if (heldKeys.Has(vkHex))
            heldKeys.Delete(vkHex)
    } else if (a.key != "") {
        try Send("{blind}{" a.key " " state "}")
    }
}

ReleaseHeldKeys(heldKeys) {
    for vkHex, v in heldKeys {
        try Send("{blind}{vk" vkHex " up}")
    }
    heldKeys.Clear()
}

StopPlayback(*) {
    global S
    if (S.Playing) {
        S.StopRequested := true
        ShowStatus("Stopping...", 1200)
    } else {
        ShowStatus("Nothing is playing.", 1200)
    }
}

;===============================================================================
;  EMERGENCY KILL SWITCH
;===============================================================================
EmergencyStop(*) {
    global S, KILL_MODE, g_RegionCapture, g_HKCapture
    S.StopRequested := true
    ToolTip()
    if IsObject(g_RegionCapture)
        EndRegionCapture(false)              ; tear down any capture overlay
    if IsObject(g_HKCapture) {
        try g_HKCapture.ih.Stop()
    }
    if (KILL_MODE = "Stop") {
        if (S.Recording)
            StopRecording()
        ShowStatus("EMERGENCY STOP — everything halted.", 3000)
    } else {
        Reload
    }
}

;===============================================================================
;  IMAGE RECOGNITION
;===============================================================================
RunImageChecks() {
    global g_ImageRules
    for i, rule in g_ImageRules {
        res := ImageRuleSearch(rule, &fx, &fy)
        if (res = 1) {                       ; ---------- image FOUND ----------
            switch rule.ActionIfFound {
                case "Click":
                    ClickImageMatch(rule, fx, fy)
                    if (rule.Notify)
                        ShowStatus("Image Found!  " rule.Name "  ->  clicked at " fx "," fy, 1500)
                case "StopMacro":
                    ShowStatus("Image Found!  " rule.Name "  ->  macro stopped", 3000)
                    return false
                case "Ignore":
                    if (rule.Notify)
                        ShowStatus("Image Found!  " rule.Name "  ->  ignored", 1000)
                default:
                    ShowStatus("Unknown ActionIfFound '" rule.ActionIfFound "' on rule '" rule.Name "'", 2500)
            }
            ; zones with an "On Image Match" trigger linked to this rule fire now
            RunZoneImageTriggers(rule.Name)
        } else if (res = 0) {                ; ---------- image NOT found ----------
            switch rule.ActionIfNotFound {
                case "StopMacro":
                    ShowStatus("Image NOT found:  " rule.Name "  ->  macro stopped", 3000)
                    return false
                case "Click", "Ignore":
                    ; nothing sensible to do when the image is absent — continue
            }
        } else {                             ; ---------- file problem ----------
            if (!rule.Warned) {
                rule.Warned := true
                ShowStatus("Image file missing/unreadable: " rule.Path "  (rule skipped)", 3000)
            }
        }
    }
    return true
}

ImageRuleSearch(rule, &foundX, &foundY) {
    global g_ImageRules
    path := ResolveImagePath(rule.Path)
    foundX := 0, foundY := 0
    if !FileExist(path)
        return -1
    tol := Min(255, Max(0, Round(rule.Tolerance)))
    opts := (tol > 0) ? "*" tol " " : ""
    ; ---- search area priority: linked Hitbox Zone > rule.Region > full screen ----
    x1 := 0, y1 := 0, x2 := A_ScreenWidth - 1, y2 := A_ScreenHeight - 1
    areaSet := false
    if (rule.Zone != "") {
        z := FindZone(rule.Zone)
        if IsObject(z) && z.X2 > z.X1 && z.Y2 > z.Y1 {
            x1 := z.X1, y1 := z.Y1, x2 := z.X2, y2 := z.Y2
            areaSet := true                  ; searching only this zone = fast + accurate
        }
    }
    if (!areaSet && rule.Region != "") {
        r := StrSplit(rule.Region, ",")
        if (r.Length = 4) {
            x1 := ToNumber(r[1], 0), y1 := ToNumber(r[2], 0)
            x2 := ToNumber(r[3], 0), y2 := ToNumber(r[4], 0)
        }
    }
    try
        res := ImageSearch(&foundX, &foundY, x1, y1, x2, y2, opts path)
    catch
        return -1
    if (res = 1 && rule.W = 0) {
        dims := GetImageSize(path)
        rule.W := dims.w, rule.H := dims.h
    }
    return res
}

ClickImageMatch(rule, fx, fy) {
    if (rule.W > 0)
        MouseClick("Left", fx + rule.W // 2, fy + rule.H // 2, 1)
    else
        MouseClick("Left", fx, fy, 1)
}

GetImageSize(imgPath) {
    static cache := Map()
    if (cache.Has(imgPath))
        return cache[imgPath]
    dims := {w: 0, h: 0}
    try {
        tmp := Gui()
        pic := tmp.AddPicture("", imgPath)
        pic.GetPos(&px, &py, &w, &h)
        dims := {w: w, h: h}
        tmp.Destroy()
    } catch {
    }
    cache[imgPath] := dims
    return dims
}

ResolveImagePath(p) {
    if (SubStr(p, 2, 2) = ":\" || SubStr(p, 1, 2) = "\\")
        return p
    return A_ScriptDir "\" p
}

FindImageRule(name) {
    global g_ImageRules
    for rule in g_ImageRules
        if (rule.Name = name)
            return rule
    return 0
}

HasUsableImageRule() {
    global g_ImageRules
    for i, rule in g_ImageRules {
        if FileExist(ResolveImagePath(rule.Path))
            return true
    }
    return false
}

CheckImageFiles() {
    global g_ImageRules
    miss := ""
    for i, rule in g_ImageRules {
        if !FileExist(ResolveImagePath(rule.Path))
            miss .= "   " rule.Path "`n"
    }
    return miss
}

TestImageSearch(*) {
    global g_ImageRules
    report := ""
    for i, rule in g_ImageRules {
        res := ImageRuleSearch(rule, &fx, &fy)
        if (res = 1)
            line := "FOUND at " fx "," fy
        else if (res = 0)
            line := "not found in search area"
        else
            line := "FILE ERROR (missing or unreadable)"
        area := "full screen"
        if (rule.Zone != "" && IsObject(FindZone(rule.Zone)))
            area := "zone '" rule.Zone "'"
        else if (rule.Region != "")
            area := "region " rule.Region
        report .= rule.Name "  (" rule.Path ")`n      area: " area "`n      ->  " line "`n`n"
    }
    if (report = "")
        report := "No image rules configured.`n`nAdd entries to g_ImageRules in the script."
    MsgBox(report, "Image search test")
}

;===============================================================================
;  HITBOX ZONE MANAGER — GUI
;===============================================================================
OpenZoneManager(*) {
    global ZONE_MGR, g_ImageRules
    if IsObject(ZONE_MGR) {
        ZONE_MGR.Show()
        RefreshZoneList()
        return
    }
    m := Gui(, "Hitbox Zone Manager")
    m.SetFont("s10", "Segoe UI")

    m.Add("Text", "x12 y10 w450", "Defined zones  (double-click a row to edit it):")
    m.Add("ListView", "x12 y32 w596 h150 -Multi vZoneLV",
          ["Name", "Region (x1,y1 – x2,y2)", "Action", "Auto trigger", "Linked image", "Hotkey", "On"])
    lv := m["ZoneLV"]
    lv.ModifyCol(1, 90), lv.ModifyCol(2, 165), lv.ModifyCol(3, 115)
    lv.ModifyCol(4, 92), lv.ModifyCol(5, 82), lv.ModifyCol(6, 60), lv.ModifyCol(7, 32)
    lv.OnEvent("DoubleClick", ZoneLvDouble)

    m.Add("Button", "x12 y188 w80",   "New zone").OnEvent("Click", ZoneNew)
    m.Add("Button", "x96 y188 w56",   "Edit").OnEvent("Click", ZoneEditSelected)
    m.Add("Button", "x156 y188 w66",  "Delete").OnEvent("Click", ZoneDelete)
    m.Add("Button", "x226 y188 w76",  "On/Off").OnEvent("Click", ZoneToggle)
    m.Add("Button", "x306 y188 w100", "Execute now").OnEvent("Click", ZoneExecuteSel)
    m.Add("Button", "x538 y188 w70",  "Close").OnEvent("Click", (*) => m.Hide())

    m.Add("GroupBox", "x12 y224 w596 h246", " Zone editor ")

    m.Add("Text",   "x24 y250 w40",  "Name:")
    m.Add("Edit",   "x66 y246 w150 vZoneName")
    m.Add("Text",   "x226 y250 w46", "Hotkey:")
    m.Add("Edit",   "x276 y246 w100 vZoneHK")
    m.Add("Button", "x382 y245 w80 vZoneHKBtn", "Set key...").OnEvent("Click", StartHotkeyCapture)
    m.Add("Text",   "x470 y250 w130", "e.g. ^!b  (= Ctrl+Alt+B)")

    m.Add("Text",   "x24 y282 w140", "Region  X1, Y1, X2, Y2:")
    m.Add("Edit",   "x166 y278 w56 vZoneX1", "0")
    m.Add("Edit",   "x226 y278 w56 vZoneY1", "0")
    m.Add("Edit",   "x286 y278 w56 vZoneX2", "0")
    m.Add("Edit",   "x346 y278 w56 vZoneY2", "0")
    m.Add("Button", "x412 y277 w184", "Capture region (drag)...").OnEvent("Click", ZoneCaptureRegion)

    m.Add("Text",   "x24 y314 w44",  "Action:")
    m.Add("DDL",    "x66 y310 w150 vZoneAction", ZONE_ACTIONS)
    m.Add("Text",   "x226 y314 w70", "Notches:")
    m.Add("Edit",   "x298 y310 w48 vZoneNotches", "3")
    m.Add("Text",   "x352 y314 w240", "(scroll actions only: 1–20 wheel notches)")

    m.Add("Text",   "x24 y346 w80",  "Auto trigger:")
    m.Add("DDL",    "x106 y342 w130 vZoneTrigger", ZONE_TRIGGERS)
    m.Add("Text",   "x242 y346 w48", "Every N:")
    m.Add("Edit",   "x292 y342 w48 vZoneEveryN", "1")
    m.Add("Text",   "x346 y346 w76", "Linked image:")
    m.Add("DDL",    "x424 y342 w172 vZoneImage", BuildImageNameList())

    m.Add("Text",   "x24 y378 w570 h34",
          "Hotkey = fires anytime.  'Every N loops' = fires during playback after every Nth loop.`n'On Image Match' = fires when the linked image is found during playback.")
    m.Add("Button", "x24 y414 w120", "Save zone").OnEvent("Click", SaveZoneFromEditor)
    m.Add("Button", "x150 y414 w100", "Clear form").OnEvent("Click", (*) => ClearZoneForm())

    m.OnEvent("Close",  (*) => m.Hide())     ; hide, keep object alive for reuse
    m.OnEvent("Escape", (*) => m.Hide())
    m.Show()
    ZONE_MGR := m
    ClearZoneForm()
    RefreshZoneList()
}

BuildImageNameList() {
    global g_ImageRules
    list := ["(none)"]
    for rule in g_ImageRules
        list.Push(rule.Name)
    return list
}

RefreshZoneList() {
    global ZONE_MGR, g_HitboxZones
    if !IsObject(ZONE_MGR)
        return
    lv := ZONE_MGR["ZoneLV"]
    lv.Delete()
    for z in g_HitboxZones
        lv.Add("", z.Name, z.RegionStr(), z.Action, ZoneTriggerText(z),
               (z.LinkedImage = "" ? "—" : z.LinkedImage), z.Hotkey, z.Enabled ? "Yes" : "No")
}

ZoneTriggerText(z) {
    switch z.AutoTrigger {
        case "Every N Loops":  return "Every " z.EveryN " loop(s)"
        case "On Image Match": return "Image: " (z.LinkedImage = "" ? "?" : z.LinkedImage)
        default:               return "None"
    }
}

SelectedZone() {
    global ZONE_MGR
    if !IsObject(ZONE_MGR)
        return 0
    lv := ZONE_MGR["ZoneLV"]
    row := lv.GetNext(0)
    if (row = 0)
        return 0
    return FindZone(lv.GetText(row, 1))
}

ZoneLvDouble(lv, row) {
    z := FindZone(lv.GetText(row, 1))
    if IsObject(z)
        LoadZoneToEditor(z)
}

ZoneEditSelected(*) {
    z := SelectedZone()
    if IsObject(z)
        LoadZoneToEditor(z)
    else
        ShowStatus("Select a zone in the list first.", 2000)
}

ZoneNew(*) {
    global S, g_ZoneEditing
    if (S.Recording || S.Playing) {
        ShowStatus("Stop recording/playback first.", 2500)
        return
    }
    g_ZoneEditing := 0
    ClearZoneForm()
    StartRegionCapture(FillRegionEdits)      ; immediately let the user drag a region
}

ZoneCaptureRegion(*) {
    global S
    if (S.Recording || S.Playing) {
        ShowStatus("Stop recording/playback first.", 2500)
        return
    }
    StartRegionCapture(FillRegionEdits)
}

FillRegionEdits(x1, y1, x2, y2) {
    global ZONE_MGR
    ZONE_MGR["ZoneX1"].Value := x1
    ZONE_MGR["ZoneY1"].Value := y1
    ZONE_MGR["ZoneX2"].Value := x2
    ZONE_MGR["ZoneY2"].Value := y2
    ShowStatus("Region captured: " x1 "," y1 " – " x2 "," y2, 2500)
}

ZoneDelete(*) {
    global g_HitboxZones, g_ZoneEditing
    z := SelectedZone()
    if !IsObject(z) {
        ShowStatus("Select a zone in the list first.", 2000)
        return
    }
    if (MsgBox("Delete zone '" z.Name "'?", "Confirm", "YesNo Icon?") != "Yes")
        return
    for i, zz in g_HitboxZones {
        if (zz = z) {
            g_HitboxZones.RemoveAt(i)
            break
        }
    }
    if (g_ZoneEditing = z) {
        g_ZoneEditing := 0
        ClearZoneForm()
    }
    SaveZones(), RefreshZoneList(), ApplyZoneHotkeys()
    ShowStatus("Zone deleted.", 2000)
}

ZoneToggle(*) {
    z := SelectedZone()
    if IsObject(z) {
        z.Enabled := !z.Enabled
        SaveZones(), RefreshZoneList(), ApplyZoneHotkeys()
    } else {
        ShowStatus("Select a zone first.", 2000)
    }
}

ZoneExecuteSel(*) {
    z := SelectedZone()                      ; manual execution — works even if disabled
    if IsObject(z)
        ExecuteZone(z)
    else
        ShowStatus("Select a zone first.", 2000)
}

ClearZoneForm() {
    global ZONE_MGR, g_ZoneEditing
    g_ZoneEditing := 0
    if !IsObject(ZONE_MGR)
        return
    ZONE_MGR["ZoneName"].Value    := ""
    ZONE_MGR["ZoneX1"].Value      := 0
    ZONE_MGR["ZoneY1"].Value      := 0
    ZONE_MGR["ZoneX2"].Value      := 0
    ZONE_MGR["ZoneY2"].Value      := 0
    ZONE_MGR["ZoneAction"].Choose("Click Left")
    ZONE_MGR["ZoneNotches"].Value := 3
    ZONE_MGR["ZoneTrigger"].Choose("None")
    ZONE_MGR["ZoneEveryN"].Value  := 1
    ZONE_MGR["ZoneImage"].Choose("(none)")
    ZONE_MGR["ZoneHK"].Value      := ""
}

LoadZoneToEditor(z) {
    global ZONE_MGR, g_ZoneEditing
    g_ZoneEditing := z
    ZONE_MGR["ZoneName"].Value    := z.Name
    ZONE_MGR["ZoneX1"].Value      := z.X1
    ZONE_MGR["ZoneY1"].Value      := z.Y1
    ZONE_MGR["ZoneX2"].Value      := z.X2
    ZONE_MGR["ZoneY2"].Value      := z.Y2
    ZONE_MGR["ZoneAction"].Choose(z.Action)
    ZONE_MGR["ZoneNotches"].Value := z.ScrollNotches
    ZONE_MGR["ZoneTrigger"].Choose(z.AutoTrigger)
    ZONE_MGR["ZoneEveryN"].Value  := z.EveryN
    if (z.LinkedImage != "" && InArray(BuildImageNameList(), z.LinkedImage))
        ZONE_MGR["ZoneImage"].Choose(z.LinkedImage)
    else
        ZONE_MGR["ZoneImage"].Choose("(none)")
    ZONE_MGR["ZoneHK"].Value      := z.Hotkey
    ShowStatus("Editing zone '" z.Name "'.", 1500)
}

SaveZoneFromEditor(*) {
    global ZONE_MGR, g_HitboxZones, g_ZoneEditing, ZONE_ACTIONS, ZONE_TRIGGERS
    name := Trim(ZONE_MGR["ZoneName"].Value)
    if (name = "") {
        ShowStatus("Zone name cannot be empty.", 2500)
        return
    }
    x1 := ToNumber(ZONE_MGR["ZoneX1"].Value, -1)
    y1 := ToNumber(ZONE_MGR["ZoneY1"].Value, -1)
    x2 := ToNumber(ZONE_MGR["ZoneX2"].Value, -1)
    y2 := ToNumber(ZONE_MGR["ZoneY2"].Value, -1)
    if (x1 < 0 || y1 < 0 || x2 <= x1 || y2 <= y1) {
        ShowStatus("Invalid region — use 'Capture region' or enter X2>X1 and Y2>Y1.", 3000)
        return
    }
    action := ZONE_MGR["ZoneAction"].Text
    if !InArray(ZONE_ACTIONS, action)
        action := "Click Left"
    notches := Round(ToNumber(ZONE_MGR["ZoneNotches"].Value, 3))
    notches := Min(20, Max(1, notches))
    trig := ZONE_MGR["ZoneTrigger"].Text
    if !InArray(ZONE_TRIGGERS, trig)
        trig := "None"
    everyN := Max(1, Round(ToNumber(ZONE_MGR["ZoneEveryN"].Value, 1)))
    img := ZONE_MGR["ZoneImage"].Text
    if (img = "(none)")
        img := ""
    else if !FindImageRule(img) {
        ShowStatus("Linked image '" img "' does not exist — pick one from the list.", 3000)
        return
    }
    hk := Trim(ZONE_MGR["ZoneHK"].Value)

    dupe := FindZone(name)
    if (IsObject(dupe) && dupe != g_ZoneEditing) {
        ShowStatus("A zone named '" name "' already exists — pick another name.", 2500)
        return
    }
    if IsObject(g_ZoneEditing)
        z := g_ZoneEditing
    else {
        z := HitboxZone()
        g_HitboxZones.Push(z)
    }
    z.Name := name
    z.X1 := x1, z.Y1 := y1, z.X2 := x2, z.Y2 := y2
    z.Action        := action
    z.ScrollNotches := notches
    z.AutoTrigger   := trig
    z.EveryN        := everyN
    z.LinkedImage   := img
    z.Hotkey        := hk

    SaveZones()
    RefreshZoneList()
    ApplyZoneHotkeys()
    g_ZoneEditing := z
    ShowStatus("Zone '" name "' saved.", 2000)
}

;===============================================================================
;  HITBOX ZONES — LOOKUP, EXECUTION, TRIGGERS
;===============================================================================
FindZone(name) {
    global g_HitboxZones
    for z in g_HitboxZones
        if (z.Name = name)
            return z
    return 0
}

InArray(arr, val) {
    for v in arr
        if (v = val)
            return true
    return false
}

; Executes a zone's action. Scroll actions park the mouse over the zone's
; center first (wheel events go to whatever is under the cursor).
ExecuteZone(z) {
    if !IsObject(z)
        return
    if (z.X2 <= z.X1 || z.Y2 <= z.Y1)
        return
    cx := z.CenterX(), cy := z.CenterY()
    switch z.Action {
        case "Click Left":         Click(cx, cy)
        case "Click Right":        Click(cx, cy, "Right")
        case "Double Click":       Click(cx, cy, , 2)
        case "Random Left Click":  Click(Random(z.X1, z.X2), Random(z.Y1, z.Y2))
        case "Random Right Click": Click(Random(z.X1, z.X2), Random(z.Y1, z.Y2), "Right")
        case "Scroll Up", "Scroll Down":
            Click(cx, cy)          ; position the cursor over the zone first
            Send("{Wheel" (z.Action = "Scroll Up" ? "Up" : "Down") " " z.ScrollNotches "}")
        case "Hover / Move":       MouseMove(cx, cy, 5)
    }
}

; "Every N loops" trigger — called once per completed playback loop
RunZoneLoopTriggers(loopsDone) {
    global g_HitboxZones, g_InterZoneDelay, S
    for z in g_HitboxZones {
        if (!z.Enabled || z.AutoTrigger != "Every N Loops")
            continue
        if (Mod(loopsDone, Max(1, Round(z.EveryN))) != 0)
            continue
        if !WaitDelay(g_InterZoneDelay)
            return false
        ExecuteZone(z)
        ShowStatus("Hitbox '" z.Name "' fired (after loop " loopsDone ").", 1500)
    }
    return !S.StopRequested
}

; "On Image Match" trigger — called when an image rule is FOUND during playback
RunZoneImageTriggers(imageName) {
    global g_HitboxZones, g_InterZoneDelay
    for z in g_HitboxZones {
        if (!z.Enabled || z.AutoTrigger != "On Image Match" || z.LinkedImage != imageName)
            continue
        if !WaitDelay(g_InterZoneDelay)
            return
        ExecuteZone(z)
        ShowStatus("Hitbox '" z.Name "' fired (image: " imageName ").", 1500)
    }
}

;===============================================================================
;  HITBOX ZONES — HOTKEYS (one zone hotkey can drive several zones)
;===============================================================================
ApplyZoneHotkeys() {
    global g_HitboxZones, g_ZoneHotkeys
    for i, hk in g_ZoneHotkeys               ; unregister the previous set
        try Hotkey(hk, , "Off")
    g_ZoneHotkeys := []
    byHk := Map()
    for z in g_HitboxZones {
        hk := Trim(z.Hotkey)
        if (hk = "" || !z.Enabled)
            continue
        if !byHk.Has(hk)
            byHk[hk] := []
        byHk[hk].Push(z.Name)
    }
    for hk, names in byHk {
        try {
            Hotkey(hk, ZoneHotkeyHandler.Bind(names.Clone()))
            g_ZoneHotkeys.Push(hk)
        } catch as e {
            ShowStatus("Zone hotkey '" hk "' could not be registered: " e.Message, 3000)
        }
    }
}

ZoneHotkeyHandler(names, *) {
    for name in names {
        z := FindZone(name)
        if IsObject(z) && z.Enabled
            ExecuteZone(z)
    }
}

;===============================================================================
;  HITBOX ZONES — INTERACTIVE REGION CAPTURE (click-and-drag overlay)
;===============================================================================
; Shows a see-through full-screen overlay; the user drags a rectangle with the
; left button; the limed-out frame follows the mouse. Esc cancels. When the
; drag ends, callback(x1, y1, x2, y2) receives the normalized coordinates.
StartRegionCapture(callback) {
    global g_RegionCapture, S
    if IsObject(g_RegionCapture)
        return
    if (S.Recording || S.Playing) {
        ShowStatus("Stop recording/playback first.", 2500)
        return
    }
    ov := Gui("+AlwaysOnTop -Caption +ToolWindow")
    ov.BackColor := "0A0A0A"                 ; this exact color becomes transparent
    ov.Show("x0 y0 w" A_ScreenWidth " h" A_ScreenHeight)
    WinSetTransColor("0A0A0A", ov.Hwnd, 140) ; everything else dims to 140 alpha
    ov.OnEvent("Escape", (*) => EndRegionCapture(false))
    ov.Add("Text", "x0 y16 w" A_ScreenWidth " h24 Center cLime",
           "Drag anywhere to select a hitbox region — Esc to cancel")
    ; four thin controls form the rubber-band frame
    fT := ov.Add("Text", "x0 y0 w2 h2 BackgroundLime")
    fB := ov.Add("Text", "x0 y0 w2 h2 BackgroundLime")
    fL := ov.Add("Text", "x0 y0 w2 h2 BackgroundLime")
    fR := ov.Add("Text", "x0 y0 w2 h2 BackgroundLime")
    g_RegionCapture := {ov: ov, cb: callback, dragging: false,
                        sx: 0, sy: 0, ex: 0, ey: 0, f: [fT, fB, fL, fR]}
    SetTimer(RegionCaptureWatch, 15)
    ShowStatus("Drag to select the region...", 0)
}

RegionCaptureWatch() {
    global g_RegionCapture
    if !IsObject(g_RegionCapture) {
        SetTimer(RegionCaptureWatch, 0)
        return
    }
    c := g_RegionCapture
    if GetKeyState("LButton", "P") {         ; physical state — works over our overlay
        MouseGetPos(&mx, &my)
        if !c.dragging {
            c.dragging := true
            c.sx := mx, c.sy := my
        }
        c.ex := mx, c.ey := my
        UpdateCaptureFrame()
    } else if (c.dragging) {                 ; button released -> done
        EndRegionCapture(true)
    }
}

UpdateCaptureFrame() {
    c := g_RegionCapture
    x1 := Min(c.sx, c.ex), y1 := Min(c.sy, c.ey)
    x2 := Max(c.sx, c.ex), y2 := Max(c.sy, c.ey)
    w := x2 - x1, h := y2 - y1
    t := 2                                   ; frame thickness
    c.f[1].Move(x1, y1, w, t)                ; top edge
    c.f[2].Move(x1, y2 - t, w, t)            ; bottom edge
    c.f[3].Move(x1, y1, t, h)                ; left edge
    c.f[4].Move(x2 - t, y1, t, h)            ; right edge
}

EndRegionCapture(success := true) {
    global g_RegionCapture
    SetTimer(RegionCaptureWatch, 0)
    c := g_RegionCapture
    g_RegionCapture := 0
    if !IsObject(c)
        return
    cb := c.cb
    x1 := Min(c.sx, c.ex), y1 := Min(c.sy, c.ey)
    x2 := Max(c.sx, c.ex), y2 := Max(c.sy, c.ey)
    try c.ov.Destroy()
    if !success
        return
    if (x2 - x1 < 4 || y2 - y1 < 4) {        ; treat a plain click as a cancel
        ShowStatus("Region too small — capture cancelled.", 2500)
        return
    }
    cb(x1, y1, x2, y2)
}

;===============================================================================
;  HITBOX ZONES — HOTKEY CAPTURE ("Set key..." button)
;===============================================================================
StartHotkeyCapture(*) {
    global g_HKCapture, ZONE_MGR, S
    if (S.Recording || S.Playing) {
        ShowStatus("Stop recording/playback first.", 2500)
        return
    }
    if IsObject(g_HKCapture) || !IsObject(ZONE_MGR)
        return
    ZONE_MGR["ZoneHKBtn"].Focus()            ; keep typed keys out of the edit box
    ShowStatus("Press the key combination to assign (Esc = cancel)...", 0)
    ih := InputHook("V T8")                  ; pass-through, 8s timeout
    ih.KeyOpt("{All}", "N")                  ; notify on every key
    g_HKCapture := {ih: ih, got: false}
    ih.OnKeyDown := HKCapKeyDown
    ih.OnEnd    := HKCapEnd
    ih.Start()
}

HKCapKeyDown(ih, vk, sc) {
    global g_HKCapture, ZONE_MGR
    ; bare modifiers don't count — wait for the actual key of the combo
    if (vk = 0x10 || vk = 0x11 || vk = 0x12 || vk = 0x5B || vk = 0x5C)
        return
    if IsObject(g_HKCapture)
        g_HKCapture.got := true
    key := KeyNameFromHook(vk, sc)
    if (key = "")
        key := "vk" Format("{:X}", vk)
    try ih.Stop()
    if (key = "Escape") {
        ShowStatus("Hotkey capture cancelled.", 1500)
        return
    }
    ; build the hotkey string from the modifiers held right now
    hk := ""
    if GetKeyState("Ctrl", "P")
        hk .= "^"
    if GetKeyState("Alt", "P")
        hk .= "!"
    if GetKeyState("Shift", "P")
        hk .= "+"
    if (GetKeyState("LWin", "P") || GetKeyState("RWin", "P"))
        hk .= "#"
    hk .= key
    ; validate with a throwaway registration
    valid := true
    try Hotkey(hk, (*) => 0)
    catch
        valid := false
    if valid {
        Hotkey(hk, , "Off")                  ; discard the throwaway handler
        ApplyZoneHotkeys()                   ; restore any zone hotkey it displaced
        ZONE_MGR["ZoneHK"].Value := hk
        warn := (hk = key && StrLen(key) = 1) ? "   [no modifiers — fires on every press of that key!]" : ""
        ShowStatus("Captured hotkey: " hk warn, 2500)
    } else {
        ShowStatus("'" hk "' is not a valid hotkey — try again.", 2500)
    }
}

HKCapEnd(ih) {
    global g_HKCapture
    if IsObject(g_HKCapture) && !g_HKCapture.got
        ShowStatus("Hotkey capture cancelled.", 1500)
    g_HKCapture := 0
}

;===============================================================================
;  HITBOX ZONES — PERSISTENCE (hitboxes.json next to the script)
;===============================================================================
SaveZones() {
    global g_HitboxZones, ZONE_FILE
    arr := []
    for z in g_HitboxZones {
        arr.Push(Map(
            "name",    z.Name,
            "x1",      z.X1, "y1", z.Y1, "x2", z.X2, "y2", z.Y2,
            "action",  z.Action,
            "notches", z.ScrollNotches,
            "trigger", z.AutoTrigger,
            "everyN",  z.EveryN,
            "image",   z.LinkedImage,
            "hotkey",  z.Hotkey,
            "enabled", z.Enabled))
    }
    try {
        f := FileOpen(ZONE_FILE, "w", "UTF-8")
        f.Write(JsonEncode(arr))
        f.Close()
    } catch as e {
        ShowStatus("Could not save zones: " e.Message, 3000)
    }
}

LoadZones() {
    global g_HitboxZones, ZONE_FILE, ZONE_ACTIONS, ZONE_TRIGGERS
    if !FileExist(ZONE_FILE)
        return
    try
        data := JsonParser(FileRead(ZONE_FILE, "UTF-8")).Parse()
    catch
        return
    if !(data is Array)
        return
    for m in data {
        if !(m is Map)
            continue
        z := HitboxZone(MapDef(m, "name", "Zone"),
                        ToNumber(MapDef(m, "x1", 0), 0), ToNumber(MapDef(m, "y1", 0), 0),
                        ToNumber(MapDef(m, "x2", 0), 0), ToNumber(MapDef(m, "y2", 0), 0))
        act := MapDef(m, "action", "Click Left")
        z.Action := InArray(ZONE_ACTIONS, act) ? act : "Click Left"
        z.ScrollNotches := Min(20, Max(1, Round(ToNumber(MapDef(m, "notches", 3), 3))))
        trg := MapDef(m, "trigger", "None")
        z.AutoTrigger := InArray(ZONE_TRIGGERS, trg) ? trg : "None"
        z.EveryN      := Max(1, Round(ToNumber(MapDef(m, "everyN", 1), 1)))
        z.LinkedImage := MapDef(m, "image", "")
        z.Hotkey      := MapDef(m, "hotkey", "")
        z.Enabled     := MapDef(m, "enabled", true) ? true : false
        g_HitboxZones.Push(z)
    }
}

MapDef(m, k, d) {
    return m.Has(k) ? m[k] : d
}

;===============================================================================
;  SAVE / LOAD MACROS
;===============================================================================
SaveMacroToFile(*) {
    global S
    if (S.Recording) {
        ShowStatus("Stop recording before saving.", 2500)
        return
    }
    if (S.Actions.Length = 0) {
        ShowStatus("Nothing to save — record a macro first.", 2500)
        return
    }
    ReadGuiSettings()
    path := FileSelect("S", A_ScriptDir, "Save macro as...",
                       "Macro files (*.macro)|All files (*.*)")
    if (path = "")
        return
    if !RegExMatch(path, "\.macro$")
        path .= ".macro"
    payload := Map(
        "format",      "AHK-v2-SmartMacroRecorder",
        "version",     1,
        "speed",       S.Speed,
        "loopCount",   S.Loops,
        "actionCount", S.Actions.Length,
        "actions",     S.Actions
    )
    try {
        f := FileOpen(path, "w", "UTF-8")
        f.Write(JsonEncode(payload))
        f.Close()
        ShowStatus("Saved " S.Actions.Length " actions to:`n" path, 4000)
    } catch as e {
        MsgBox("Could not save the file:`n`n" e.Message, "Save failed", "Icon!")
    }
}

LoadMacroFromFile(*) {
    global S
    if (S.Recording || S.Playing) {
        ShowStatus("Stop recording/playback before loading a file.", 2500)
        return
    }
    path := FileSelect(1, A_ScriptDir, "Load macro...",
                       "Macro files (*.macro)|All files (*.*)")
    if (path = "")
        return
    try {
        text := FileRead(path, "UTF-8")
        data := JsonParser(text).Parse()
        raw := (data is Map && data.Has("actions")) ? data["actions"] : data
        if !(raw is Array)
            throw Error("The file contains no actions array.")
        S.Actions := NormalizeActions(raw)
        if (data is Map) {
            spd := data.Has("speed") ? ToNumber(data["speed"], 0) : 0
            if (spd > 0)
                S.Gui["SpeedMultiplier"].Value := spd
            if (data.Has("loopCount")) {
                lc := ToNumber(data["loopCount"], 1)
                S.Gui["LoopCount"].Value := (lc < 0) ? 1 : Round(lc)
            }
        }
        ShowStatus("Loaded " S.Actions.Length " actions from:`n" path, 4000)
    } catch as e {
        MsgBox("Could not load the macro:`n`n" e.Message, "Load failed", "Icon!")
    }
}

NormalizeActions(raw) {
    out := []
    for i, m in raw {
        if !(m is Map)
            continue
        t := m.Has("type") ? m["type"] : ""
        if (t != "click" && t != "key")
            continue
        a := {type: t, delay: ToNumber(m.Has("delay") ? m["delay"] : 0, 0)}
        if (t = "click") {
            a.x      := ToNumber(m.Has("x") ? m["x"] : 0, 0)
            a.y      := ToNumber(m.Has("y") ? m["y"] : 0, 0)
            a.button := m.Has("button") ? m["button"] : "Left"
        } else {
            a.key   := m.Has("key") ? m["key"] : ""
            a.state := (m.Has("state") && m["state"] = "up") ? "up" : "down"
            if (m.Has("vk") && m["vk"] != "")
                a.vk := m["vk"]
        }
        out.Push(a)
    }
    return out
}

;===============================================================================
;  UTILITIES & STATUS OVERLAYS
;===============================================================================
ReadGuiSettings() {
    global S
    if !IsObject(S.Gui)
        return
    v := S.Gui.Submit(0)
    S.RecordMouse    := (v.RecordMouse = 1)
    S.RecordKeyboard := (v.RecordKeyboard = 1)
    S.ImageRec       := (v.ImageRec = 1)
    S.Speed          := ToNumber(v.SpeedMultiplier, 1.0)
    if (S.Speed <= 0) {
        S.Speed := 1.0
        ShowStatus("Invalid speed multiplier — using 1.0", 2500)
    }
    loops := ToNumber(v.LoopCount, 1)
    S.Loops := (loops < 0) ? 1 : Round(loops)   ; 0 = infinite
}

ShowStatus(text, duration := 2000) {
    global S
    ToolTip(text, 16, A_ScreenHeight - 140)
    if IsObject(S.Gui) {
        try S.Gui["StatusText"].Text := StrReplace(text, "`n", "   ")
    }
    if (duration > 0)
        SetTimer(ClearStatusTip, -duration)
    else
        SetTimer(ClearStatusTip, 0)
}

ClearStatusTip() {
    ToolTip()
}

ToNumber(val, default) {
    if (IsObject(val))
        return default
    s := Trim(String(val))
    if (s = "")
        return default
    try {
        n := s + 0
        if IsNumber(n)
            return n
    } catch {
    }
    return default
}

;===============================================================================
;  MINI JSON ENCODER / PARSER  (only what our *.macro / *.json files need)
;===============================================================================
JsonEncode(v) {
    switch Type(v) {
        case "Array":
        {
            s := ""
            for i, item in v
                s .= (A_Index > 1 ? "," : "") JsonEncode(item)
            return "[" s "]"
        }
        case "Map":
        {
            s := ""
            for k, val in v
                s .= (A_Index > 1 ? "," : "") JsonEncodeString(String(k)) ":" JsonEncode(val)
            return "{" s "}"
        }
        case "Object":
        {
            s := ""
            for k, val in v.OwnProps()
                s .= (A_Index > 1 ? "," : "") JsonEncodeString(String(k)) ":" JsonEncode(val)
            return "{" s "}"
        }
        case "Integer", "Float":
            return String(v)
        default:
            return JsonEncodeString(String(v))
    }
}

JsonEncodeString(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`t", "\t")
    return '"' s '"'
}

class JsonParser {
    __New(text) {
        this.s := text
        this.n := StrLen(text)
        this.i := 1
    }
    Parse() {
        return this.ParseValue()
    }
    Peek() {
        return (this.i <= this.n) ? SubStr(this.s, this.i, 1) : ""
    }
    SkipWs() {
        while (this.i <= this.n && InStr(" `t`r`n", SubStr(this.s, this.i, 1)))
            this.i++
    }
    ParseValue() {
        this.SkipWs()
        c := this.Peek()
        if (c = "{")
            return this.ParseObject()
        if (c = "[")
            return this.ParseArray()
        if (c = '"')
            return this.ParseString()
        if (SubStr(this.s, this.i, 4) = "true") {
            this.i += 4
            return true
        }
        if (SubStr(this.s, this.i, 5) = "false") {
            this.i += 5
            return false
        }
        if (SubStr(this.s, this.i, 4) = "null") {
            this.i += 4
            return ""
        }
        return this.ParseNumber()
    }
    ParseObject() {
        obj := Map()
        this.i++
        this.SkipWs()
        if (this.Peek() = "}") {
            this.i++
            return obj
        }
        loop {
            this.SkipWs()
            if (this.Peek() != '"')
                throw Error("JSON: expected a key string at position " this.i)
            key := this.ParseString()
            this.SkipWs()
            if (this.Peek() != ":")
                throw Error("JSON: expected ':' at position " this.i)
            this.i++
            obj[key] := this.ParseValue()
            this.SkipWs()
            c := this.Peek()
            if (c = ",") {
                this.i++
            } else if (c = "}") {
                this.i++
                break
            } else {
                throw Error("JSON: expected ',' or '}' at position " this.i)
            }
        }
        return obj
    }
    ParseArray() {
        arr := []
        this.i++
        this.SkipWs()
        if (this.Peek() = "]") {
            this.i++
            return arr
        }
        loop {
            arr.Push(this.ParseValue())
            this.SkipWs()
            c := this.Peek()
            if (c = ",") {
                this.i++
            } else if (c = "]") {
                this.i++
                break
            } else {
                throw Error("JSON: expected ',' or ']' at position " this.i)
            }
        }
        return arr
    }
    ParseString() {
        this.i++
        out := ""
        while (this.i <= this.n) {
            c := SubStr(this.s, this.i, 1)
            if (c = '"') {
                this.i++
                return out
            }
            if (c = "\") {
                e := SubStr(this.s, this.i + 1, 1)
                switch e {
                    case "n": out .= "`n"
                    case "t": out .= "`t"
                    case "r": out .= "`r"
                    case "b": out .= Chr(8)
                    case "f": out .= Chr(12)
                    case '"': out .= '"'
                    case "/": out .= "/"
                    case "\": out .= "\"
                    case "u":
                    {
                        hex := SubStr(this.s, this.i + 2, 4)
                        if (StrLen(hex) < 4)
                            throw Error("JSON: bad \u escape at position " this.i)
                        out .= Chr(Integer("0x" hex))
                        this.i += 4
                    }
                    default:
                        throw Error("JSON: bad escape at position " this.i)
                }
                this.i += 2
            } else {
                out .= c
                this.i++
            }
        }
        throw Error("JSON: unterminated string")
    }
    ParseNumber() {
        start := this.i
        while (this.i <= this.n && InStr("-+.eE0123456789", SubStr(this.s, this.i, 1), true))
            this.i++
        if (this.i = start)
            throw Error("JSON: invalid value at position " start)
        numStr := SubStr(this.s, start, this.i - start)
        if IsInteger(numStr)
            return Integer(numStr)
        if IsFloat(numStr)
            return Float(numStr)
        throw Error("JSON: invalid number '" numStr "'")
    }
}