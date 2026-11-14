package com.bella.tinytiny

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

object AppTheme {
    val bg = Color(0xFF070709)
    val surface = Color(0xFF121216)
    val surfaceElevated = Color(0xFF1B1B22)
    val accent = Color(0xFFFF387C)
    val accentBright = Color(0xFFFF6CA0)
    val purple = Color(0xFF7D3CFF)
    val cyan = Color(0xFF3CC8FF)
    val textSecondary = Color.White.copy(alpha = 0.65f)

    val brandGradient = Brush.linearGradient(
        colors = listOf(Color(0xFFFF387C), Color(0xFFAE3CFF))
    )

    val ringGradient = Brush.sweepGradient(
        colors = listOf(
            Color(0xFFFF387C),
            Color(0xFFAE3CFF),
            Color(0xFF3CC8FF),
            Color(0xFFFF387C)
        )
    )
}

fun Modifier.liquidGlassCapsule(
    tinted: Boolean = false,
    active: Boolean = false
): Modifier {
    val fill = when {
        active -> Color(0xFFFF387C).copy(alpha = 0.28f)
        tinted -> Color(0xFF141118).copy(alpha = 0.72f)
        else -> Color(0xFF1C1C22).copy(alpha = 0.68f)
    }
    val stroke = if (active) Color(0xFFFF6CA0).copy(alpha = 0.55f) else Color.White.copy(alpha = 0.18f)
    return this
        .clip(RoundedCornerShape(999.dp))
        .background(fill)
        .border(0.8.dp, stroke, RoundedCornerShape(999.dp))
}

fun Modifier.liquidGlassCircle(
    tinted: Boolean = false,
    active: Boolean = false
): Modifier {
    val fill = when {
        active -> Color(0xFFFF387C).copy(alpha = 0.28f)
        tinted -> Color(0xFF141118).copy(alpha = 0.72f)
        else -> Color(0xFF1C1C22).copy(alpha = 0.68f)
    }
    val stroke = if (active) Color(0xFFFF6CA0).copy(alpha = 0.55f) else Color.White.copy(alpha = 0.18f)
    return this
        .clip(CircleShape)
        .background(fill)
        .border(0.8.dp, stroke, CircleShape)
}

fun Modifier.liquidGlassCard(
    cornerRadius: Dp = 18.dp,
    tinted: Boolean = false
): Modifier {
    val shape = RoundedCornerShape(cornerRadius)
    val fill = if (tinted) Color(0xFF141118).copy(alpha = 0.78f) else Color.White.copy(alpha = 0.08f)
    return this
        .clip(shape)
        .background(fill)
        .border(0.8.dp, Color.White.copy(alpha = 0.15f), shape)
}
