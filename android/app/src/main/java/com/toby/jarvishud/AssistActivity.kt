package com.toby.jarvishud

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.view.WindowManager

/** Transparent full-screen HUD. Used for ACTION_ASSIST launchers and by the wake word. */
class AssistActivity : Activity() {
    private lateinit var hud: HudView
    private var closing = false
    override fun onCreate(s: Bundle?) {
        super.onCreate(s); Prefs.init(this)
        window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        window.setFlags(WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS, WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS)
        hud = HudView(this); hud.onClose = { close() }; setContentView(hud)
        hud.post { hud.show(listen = intent.getBooleanExtra("listen", intent.getStringExtra("query").isNullOrBlank()), query = intent.getStringExtra("query")) }
    }
    override fun onNewIntent(i: Intent) { super.onNewIntent(i); intent = i; val q = i.getStringExtra("query"); if (!q.isNullOrBlank()) hud.submit(q, spoken = true) else hud.listen() }
    private fun close() { if (closing) return; closing = true; hud.hide { finish(); overridePendingTransition(0, 0) } }
    override fun onBackPressed() { close() }
    override fun onPause() { super.onPause(); hud.stopListening() }
}
