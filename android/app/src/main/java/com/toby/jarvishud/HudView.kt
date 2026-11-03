package com.toby.jarvishud

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import android.text.style.RelativeSizeSpan
import android.text.style.StyleSpan
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.*

/** The HUD: ring top-right, panel expanding leftward, output, input, mic. Used by the assistant session and the fallback activity. */
class HudView(c: Context) : FrameLayout(c) {
    private val cyan = Color.rgb(51, 217, 255); private val body = Color.rgb(179, 237, 255); private val dim = Color.argb(150, 51, 217, 255)
    private val d = resources.displayMetrics.density
    val ring = RingView(c)
    val panel = LinearLayout(c).apply { orientation = LinearLayout.VERTICAL; background = c.getDrawable(R.drawable.panel_bg); setPadding((14 * d).toInt(), (10 * d).toInt(), (14 * d).toInt(), (10 * d).toInt()) }
    val title = TextView(c).apply { text = "J.A.R.V.I.S."; setTextColor(cyan); typeface = Typeface.MONOSPACE; textSize = 15f; letterSpacing = 0.15f; setTypeface(typeface, Typeface.BOLD) }
    val output = TextView(c).apply { setTextColor(body); typeface = Typeface.MONOSPACE; textSize = 12.5f; setLineSpacing(0f, 1.15f) }
    val scroll = ScrollView(c).apply { addView(output); isVerticalScrollBarEnabled = false }
    val input = EditText(c).apply { hint = "Ask anything…"; setHintTextColor(dim); setTextColor(body); typeface = Typeface.MONOSPACE; textSize = 13f; background = c.getDrawable(R.drawable.input_bg); setPadding((10 * d).toInt(), (8 * d).toInt(), (10 * d).toInt(), (8 * d).toInt()); imeOptions = EditorInfo.IME_ACTION_SEND; setSingleLine() }
    val mic = TextView(c).apply { text = "🎙"; textSize = 20f; setPadding((10 * d).toInt(), 0, (4 * d).toInt(), 0); gravity = Gravity.CENTER }
    var onClose: (() -> Unit)? = null
    private var pendingConfirm: ((Boolean) -> Unit)? = null

    init {
        setOnClickListener { onClose?.invoke() }   // tap outside = dismiss
        val ringSize = (118 * d).toInt()
        addView(ring, LayoutParams(ringSize, ringSize, Gravity.TOP or Gravity.END).apply { topMargin = (44 * d).toInt(); rightMargin = (10 * d).toInt() })
        panel.addView(title); panel.addView(scroll, LinearLayout.LayoutParams(-1, 0, 1f).apply { topMargin = (6 * d).toInt(); bottomMargin = (8 * d).toInt() })
        val row = LinearLayout(c).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        row.addView(input, LinearLayout.LayoutParams(0, -2, 1f)); row.addView(mic)
        panel.addView(row)
        panel.setOnClickListener { }   // swallow
        addView(panel, LayoutParams(-1, (300 * d).toInt(), Gravity.TOP or Gravity.START).apply { topMargin = (100 * d).toInt(); leftMargin = (12 * d).toInt(); rightMargin = (12 * d).toInt() })
        input.setOnEditorActionListener { _, a, e -> if (a == EditorInfo.IME_ACTION_SEND || e?.keyCode == KeyEvent.KEYCODE_ENTER) { onEnter(); true } else false }
        mic.setOnClickListener { listen() }
    }

    override fun dispatchKeyEvent(e: KeyEvent): Boolean {
        if (e.keyCode == KeyEvent.KEYCODE_BACK && e.action == KeyEvent.ACTION_UP) { if (pendingConfirm != null) resolveConfirm(false) else onClose?.invoke(); return true }
        return super.dispatchKeyEvent(e)
    }

    private fun onEnter() {
        if (pendingConfirm != null) { resolveConfirm(true); return }
        submit(input.text.toString())
    }

    fun show(listen: Boolean, query: String? = null) {
        panel.pivotX = panel.width.toFloat().takeIf { it > 0 } ?: resources.displayMetrics.widthPixels.toFloat(); panel.scaleX = 0f; panel.alpha = 0f
        ring.appear()
        panel.animate().scaleX(1f).alpha(1f).setStartDelay(180).setDuration(380).withEndAction { if (listen) listen() else focusInput() }.start()
        if (!query.isNullOrBlank()) postDelayed({ submit(query, spoken = true) }, 500)
    }
    fun hide(done: () -> Unit) {
        stopListening(); hideKeyboard()
        panel.animate().scaleX(0f).alpha(0f).setDuration(220).start()
        ring.disappear(done)
    }

    private fun focusInput() { input.requestFocus(); (context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).showSoftInput(input, 0) }
    private fun hideKeyboard() { (context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager).hideSoftInputFromWindow(windowToken, 0) }

    // MARK: speech (offline Vosk; the system recognizer is often unavailable to third-party apps on Xiaomi)
    private var session: VoskEngine.Session? = null
    fun listen() {
        stopListening()
        title.text = "J.A.R.V.I.S.  — LISTENING"; mic.setTextColor(cyan)
        val sess = VoskEngine.Session(context,
            onPartial = { p -> input.setText(p); input.setSelection(p.length) },
            onFinal = { t -> stopListening(); Memory.log(context, t); submit(t, spoken = true) },
            onError = { e -> AI.log(context, "hud speech: $e"); stopListening(); title.text = "J.A.R.V.I.S."; append("JARVIS ▸", "Microphone trouble, sir ($e). Type instead."); focusInput() })
        session = sess; sess.start()
    }
    fun stopListening() { session?.stop(); session = null; mic.setTextColor(body) }

    // MARK: output
    fun append(who: String, text: String) {
        val sb = SpannableStringBuilder()
        sb.append(who + " ", ForegroundColorSpan(cyan), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE); sb.setSpan(StyleSpan(Typeface.BOLD), 0, sb.length, 0)
        sb.append(text + "\n\n")
        output.append(sb); post { scroll.fullScroll(View.FOCUS_DOWN) }
    }
    private fun replaceLastPlaceholder(replacement: CharSequence) {
        val s = output.text.toString(); val i = s.lastIndexOf("…\n\n"); if (i < 0) return
        val e = output.editableText ?: SpannableStringBuilder(output.text).also { output.text = it; }
        (output.text as? android.text.Editable)?.replace(i, i + 3, replacement) ?: run { val sb = SpannableStringBuilder(output.text); sb.replace(i, i + 3, replacement); output.text = sb }
        post { scroll.fullScroll(View.FOCUS_DOWN) }
    }
    private fun insertBeforePlaceholder(line: CharSequence) {
        val s = output.text.toString(); val i = s.lastIndexOf("…\n\n"); if (i < 0) return
        val sb = SpannableStringBuilder(output.text); sb.insert(i, line); output.text = sb; post { scroll.fullScroll(View.FOCUS_DOWN) }
    }

    fun submit(text: String, spoken: Boolean = false) {
        val q = text.trim(); if (q.isEmpty()) return
        input.setText(""); hideKeyboard()
        append(if (spoken) "YOU 🎙 ▸" else "YOU ▸", q); append("JARVIS ▸", "…")
        AI.spoken = spoken
        title.text = "J.A.R.V.I.S.  — THINKING"
        AI.onStatus = { st -> title.text = "J.A.R.V.I.S.  — $st" }
        AI.onStep = { st -> val sp = SpannableStringBuilder(st + "\n"); sp.setSpan(ForegroundColorSpan(dim), 0, sp.length, 0); sp.setSpan(RelativeSizeSpan(0.9f), 0, sp.length, 0); insertBeforePlaceholder(sp) }
        AI.onConfirm = { qq, decide -> if (isAttachedToWindow) askConfirm(qq, decide) else decide(false) }
        AI.ask(context, q) { r ->
            title.text = "J.A.R.V.I.S."
            val sb = SpannableStringBuilder(output.text); val s = sb.toString(); val i = s.lastIndexOf("…\n\n")
            if (i >= 0) { sb.replace(i, i + 1, r); output.text = sb; post { scroll.fullScroll(View.FOCUS_DOWN) } }
        }
    }

    private fun askConfirm(q: String, decide: (Boolean) -> Unit) {
        pendingConfirm = decide
        title.text = "J.A.R.V.I.S.  — ⏎ ALLOW  ⌫ DENY"
        val sp = SpannableStringBuilder("⚠ $q\n"); sp.setSpan(ForegroundColorSpan(Color.rgb(255, 190, 80)), 0, sp.length, 0); insertBeforePlaceholder(sp)
        input.hint = "Send = allow, Back = deny"; focusInput()
    }
    private fun resolveConfirm(ok: Boolean) {
        val dcd = pendingConfirm ?: return; pendingConfirm = null; input.hint = "Ask anything…"
        title.text = "J.A.R.V.I.S.  — " + if (ok) "WORKING" else "THINKING"; dcd(ok)
    }
}
