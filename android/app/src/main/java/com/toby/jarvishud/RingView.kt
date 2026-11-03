package com.toby.jarvishud

import android.content.Context
import android.graphics.*
import android.view.View
import android.view.animation.LinearInterpolator
import android.animation.ValueAnimator

/** The JARVIS ring: rotating arcs, a dotted ring and a glowing core. */
class RingView(c: Context) : View(c) {
    private val cyan = Color.rgb(51, 217, 255)
    private val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeCap = Paint.Cap.ROUND }
    private var t = 0f
    private var scale = 0f
    private val anim = ValueAnimator.ofFloat(0f, 1f).apply { duration = 4000; repeatCount = ValueAnimator.INFINITE; interpolator = LinearInterpolator(); addUpdateListener { t = it.animatedValue as Float; invalidate() } }

    fun appear() { scale = 0f; ValueAnimator.ofFloat(0f, 1f).apply { duration = 450; interpolator = android.view.animation.OvershootInterpolator(1.4f); addUpdateListener { scale = it.animatedValue as Float } }.start(); anim.start() }
    fun disappear(done: () -> Unit) { ValueAnimator.ofFloat(scale, 0f).apply { duration = 250; addUpdateListener { scale = it.animatedValue as Float }; doOnEnd { anim.cancel(); done() } }.start() }
    private fun ValueAnimator.doOnEnd(f: () -> Unit) = addListener(object : android.animation.AnimatorListenerAdapter() { override fun onAnimationEnd(a: android.animation.Animator) = f() })

    override fun onDraw(cv: Canvas) {
        val cx = width / 2f; val cy = height / 2f; val R = minOf(width, height) / 2f * 0.92f * scale
        if (R <= 0) return
        val d = resources.displayMetrics.density
        // outer thin arc, rotating
        p.color = cyan; p.strokeWidth = 2.5f * d; p.alpha = 230
        cv.drawArc(cx - R, cy - R, cx + R, cy + R, 360 * t, 250f, false, p)
        p.alpha = 90; p.strokeWidth = 1f * d
        cv.drawCircle(cx, cy, R, p)
        // dotted ring, counter-rotating
        p.alpha = 160; p.strokeWidth = 4f * d; p.style = Paint.Style.FILL
        val r2 = R * 0.78f
        for (i in 0 until 36) { val a = Math.toRadians((i * 10 - 360 * t * 0.5).toDouble()); cv.drawCircle(cx + (r2 * Math.cos(a)).toFloat(), cy + (r2 * Math.sin(a)).toFloat(), 2.2f * d, p) }
        p.style = Paint.Style.STROKE
        // inner dashed arc
        p.alpha = 200; p.strokeWidth = 2f * d
        val r3 = R * 0.55f
        for (k in 0 until 3) cv.drawArc(cx - r3, cy - r3, cx + r3, cy + r3, -360 * t * 1.5f + k * 120, 70f, false, p)
        // core glow
        p.style = Paint.Style.FILL; p.alpha = 60; cv.drawCircle(cx, cy, R * 0.34f, p)
        p.alpha = 190; cv.drawCircle(cx, cy, R * 0.22f + (Math.sin(t * Math.PI * 4) * 2 * d).toFloat(), p)
        p.style = Paint.Style.STROKE
    }
}
