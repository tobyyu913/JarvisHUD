package com.toby.jarvishud

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.os.Build
import android.os.Bundle
import android.widget.Toast
import android.net.Uri
import android.provider.Settings
import android.text.InputType
import android.view.Gravity
import android.widget.*
import androidx.core.app.ActivityCompat

/** Settings + "set as default assistant". */
class MainActivity : Activity() {
    private val cyan = Color.rgb(51, 217, 255); private val body = Color.rgb(179, 237, 255)
    private lateinit var base: EditText; private lateinit var model: EditText; private lateinit var key: EditText
    private lateinit var searchKey: EditText; private lateinit var status: TextView

    override fun onCreate(s: Bundle?) {
        super.onCreate(s); Prefs.init(this)
        val d = resources.displayMetrics.density
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding((20 * d).toInt(), (40 * d).toInt(), (20 * d).toInt(), (40 * d).toInt()) }
        fun label(t: String) = TextView(this).apply { text = t; setTextColor(cyan); typeface = Typeface.MONOSPACE; textSize = 12f; letterSpacing = 0.1f; setPadding(0, (16 * d).toInt(), 0, (4 * d).toInt()) }
        fun field(hint: String, v: String, pw: Boolean = false) = EditText(this).apply { setHint(hint); setText(v); setTextColor(body); setHintTextColor(Color.argb(120, 51, 217, 255)); typeface = Typeface.MONOSPACE; textSize = 13f; background = getDrawable(R.drawable.input_bg); setPadding((10 * d).toInt(), (8 * d).toInt(), (10 * d).toInt(), (8 * d).toInt()); if (pw) inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD }
        fun button(t: String, f: () -> Unit) = Button(this).apply { text = t; setTextColor(cyan); background = getDrawable(R.drawable.panel_bg); isAllCaps = false; typeface = Typeface.MONOSPACE; setOnClickListener { f() } }

        root.addView(TextView(this).apply { text = "J.A.R.V.I.S."; setTextColor(cyan); typeface = Typeface.MONOSPACE; textSize = 26f; letterSpacing = 0.2f; setTypeface(typeface, Typeface.BOLD) })
        status = TextView(this).apply { setTextColor(body); typeface = Typeface.MONOSPACE; textSize = 12f; setPadding(0, (8 * d).toInt(), 0, 0) }
        root.addView(status)

        root.addView(label("1 · MAKE JARVIS THE DEFAULT ASSISTANT"))
        root.addView(TextView(this).apply { text = "Settings → Apps → Default apps → Digital assistant app → JARVIS. On Xiaomi/HyperOS this replaces 小爱同学 on long-press home / power."; setTextColor(body); textSize = 12f })
        root.addView(button("Open assistant settings") { openAssistantSettings() })
        root.addView(button("Take over power button (Xiaomi)") { takeOverPowerButton() })
        root.addView(button("Grant microphone & notifications") { requestPerms() })
        root.addView(button("Test the HUD") { startActivity(Intent(this, AssistActivity::class.java)) })

        root.addView(label("2 · AI PROVIDER"))
        val sp = Spinner(this); val names = AI.presets.map { it.name }
        sp.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, names); sp.setSelection(names.indexOf(Prefs.aiName).coerceAtLeast(0))
        root.addView(sp)
        base = field("Base URL", Prefs.aiBase); model = field("Model", Prefs.aiModel); key = field("API key", Prefs.aiKey, pw = true)
        root.addView(label("base url")); root.addView(base); root.addView(label("model")); root.addView(model); root.addView(label("api key")); root.addView(key)
        val keyHint = TextView(this).apply { setTextColor(body); textSize = 11f }
        root.addView(keyHint)
        sp.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(p: AdapterView<*>?, v: android.view.View?, i: Int, id: Long) {
                val pr = AI.presets[i]; keyHint.text = "Get a key at ${pr.keyURL}"
                if (pr.name != Prefs.aiName) { base.setText(pr.base); model.setText(pr.model); key.setText("") }
            }
            override fun onNothingSelected(p: AdapterView<*>?) {}
        }

        root.addView(label("3 · WEB SEARCH (optional)"))
        val ssp = Spinner(this); ssp.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, Search.providers); ssp.setSelection(Search.providers.indexOf(Prefs.searchProvider).coerceAtLeast(0))
        root.addView(ssp); searchKey = field("Search API key (Tavily / Brave / Serper)", Prefs.searchKey, pw = true); root.addView(searchKey)

        root.addView(label("4 · WAKE WORD \"JARVIS\""))
        val wsp = Spinner(this); val modes = listOf("Automatic (while charging)", "Always on", "Off"); val vals = listOf("auto", "on", "off")
        wsp.adapter = ArrayAdapter(this, android.R.layout.simple_spinner_dropdown_item, modes); wsp.setSelection(vals.indexOf(Prefs.voiceMode).coerceAtLeast(0))
        root.addView(wsp)
        root.addView(TextView(this).apply { text = "Listens 24/7 with the phone's speech recognizer and logs everything heard (on this phone only, 14 days) so you can ask \"what did I say about…\" or \"where did I leave my keys\"."; setTextColor(body); textSize = 12f })
        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        row.addView(button("Forget today") { Memory.forgetToday(this); toast("Today's transcript deleted") }, LinearLayout.LayoutParams(0, -2, 1f))
        row.addView(button("Forget all heard") { Memory.forgetAllHeard(this); toast("Heard log deleted") }, LinearLayout.LayoutParams(0, -2, 1f))
        row.addView(button("Forget notes") { Memory.forgetAllNotes(this); toast("Notes deleted") }, LinearLayout.LayoutParams(0, -2, 1f))
        root.addView(row)

        root.addView(button("SAVE") {
            val pr = AI.presets[sp.selectedItemPosition]
            Prefs.aiName = pr.name; Prefs.aiKind = pr.kind; Prefs.aiBase = base.text.toString().trim(); Prefs.aiModel = model.text.toString().trim(); Prefs.aiKey = key.text.toString().trim()
            Prefs.searchProvider = Search.providers[ssp.selectedItemPosition]; Prefs.searchKey = searchKey.text.toString().trim()
            Prefs.voiceMode = vals[wsp.selectedItemPosition]; AI.history.clear()
            WakeService.applyMode(this); toast("Saved"); refresh()
        })
        setContentView(ScrollView(this).apply { addView(root) })
        requestPerms()
    }

    override fun onResume() { super.onResume(); refresh() }
    private fun refresh() {
        val cur = Settings.Secure.getString(contentResolver, "voice_interaction_service") ?: ""
        val isDefault = cur.startsWith(packageName)
        status.text = (if (isDefault) "✓ JARVIS is the default assistant" else "✗ Not the default assistant yet (current: ${cur.substringBefore('/').ifEmpty { "none" }})") +
            "\n" + (if (WakeService.running) "🎙 Listening for \"Jarvis\"" else "Wake word idle")
    }
    /** HyperOS hard-wires "long press power → 小爱" to Xiaomi's own package. The only value of that shortcut that goes
     *  through the system assistant role is launch_google_search, so we write that into the (world-writable with
     *  WRITE_SETTINGS) system table. */
    private fun takeOverPowerButton() {
        if (!Settings.System.canWrite(this)) {
            Toast.makeText(this, "Allow \"Modify system settings\" for JARVIS, then tap again", Toast.LENGTH_LONG).show()
            try { startActivity(Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS, Uri.parse("package:$packageName"))) } catch (_: Exception) {}
            return
        }
        var ok = 0
        for (k in listOf("long_press_power_key")) {
            val cur = Settings.System.getString(contentResolver, k)
            if (cur != null && cur.contains("xiaoai") || cur == "launch_voice_assistant")
                try { if (Settings.System.putString(contentResolver, k, "launch_google_search")) ok++ } catch (e: Exception) { AI.log(this, "putString $k: $e") }
        }
        Toast.makeText(this, if (ok > 0) "Long-press power now summons JARVIS" else "Nothing to change (already not 小爱, or not a Xiaomi)", Toast.LENGTH_LONG).show()
    }
    private fun openAssistantSettings() {
        for (a in listOf(Settings.ACTION_VOICE_INPUT_SETTINGS, Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS, Settings.ACTION_SETTINGS)) {
            try { startActivity(Intent(a)); return } catch (_: Exception) {}
        }
    }
    private fun requestPerms() {
        val need = mutableListOf(Manifest.permission.RECORD_AUDIO)
        if (Build.VERSION.SDK_INT >= 33) need += Manifest.permission.POST_NOTIFICATIONS
        val missing = need.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isNotEmpty()) ActivityCompat.requestPermissions(this, missing.toTypedArray(), 1)
    }
    override fun onRequestPermissionsResult(r: Int, p: Array<out String>, g: IntArray) { super.onRequestPermissionsResult(r, p, g); WakeService.applyMode(this); refresh() }
    private fun toast(t: String) = Toast.makeText(this, t, Toast.LENGTH_SHORT).show()
}
