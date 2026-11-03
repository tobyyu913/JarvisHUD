package com.toby.jarvishud

import android.content.Context
import android.content.SharedPreferences

object Prefs {
    lateinit var sp: SharedPreferences
    fun init(c: Context) { if (!::sp.isInitialized) sp = c.applicationContext.getSharedPreferences("jarvis", Context.MODE_PRIVATE) }
    var aiName: String get() = sp.getString("aiName", AI.presets[0].name)!!; set(v) = sp.edit().putString("aiName", v).apply()
    var aiKind: String get() = sp.getString("aiKind", AI.presets[0].kind)!!; set(v) = sp.edit().putString("aiKind", v).apply()
    var aiBase: String get() = sp.getString("aiBase", AI.presets[0].base)!!; set(v) = sp.edit().putString("aiBase", v).apply()
    var aiModel: String get() = sp.getString("aiModel", AI.presets[0].model)!!; set(v) = sp.edit().putString("aiModel", v).apply()
    var aiKey: String get() = sp.getString("aiKey", "")!!; set(v) = sp.edit().putString("aiKey", v).apply()
    var searchProvider: String get() = sp.getString("searchProvider", "Off")!!; set(v) = sp.edit().putString("searchProvider", v).apply()
    var searchKey: String get() = sp.getString("searchKey", "")!!; set(v) = sp.edit().putString("searchKey", v).apply()
    var voiceMode: String get() = sp.getString("voiceMode", "auto")!!; set(v) = sp.edit().putString("voiceMode", v).apply()   // auto | on | off
    var agentConfirm: Boolean get() = sp.getBoolean("agentConfirm", true); set(v) = sp.edit().putBoolean("agentConfirm", v).apply()
}
