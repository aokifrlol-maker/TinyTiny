package com.bella.tinytiny

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.serialization.Serializable

object Theme {
    val bg = Color(0xFF0D050A)
    val crimsonBg = Color(0xFF8F2447)
    val crimsonModal = Color(0xFF701F3B)
    val crimsonCard = Color(0xFF9E3357)
    val accent = Color(0xFFE53164)
    val accentBright = Color(0xFFFF3D75)

    val surface = Color.White.copy(alpha = 0.11f)
    val surfaceElevated = Color.White.copy(alpha = 0.17f)
    val border = Color.White.copy(alpha = 0.22f)
    val borderSubtle = Color.White.copy(alpha = 0.14f)

    val textPrimary = Color.White
    val textSecondary = Color.White.copy(alpha = 0.68f)
    val textMuted = Color.White.copy(alpha = 0.42f)

    val ringGradient = Brush.linearGradient(
        listOf(accentBright, accent, Color(0xFFAD245C))
    )

    val brandGradient = Brush.linearGradient(
        listOf(accentBright, accent)
    )

    val modalGradient = Brush.verticalGradient(
        listOf(
            Color(0xFF94294D),
            Color(0xFF6B1C38),
            Color(0xFF471226)
        )
    )
}

fun Modifier.liquidGlassCapsule(tinted: Boolean = false, active: Boolean = false): Modifier {
    val fill = when {
        active -> Theme.accent.copy(alpha = 0.88f)
        tinted -> Color(0xFF380F1F).copy(alpha = 0.62f)
        else -> Color.Black.copy(alpha = 0.36f)
    }
    val stroke = Color.White.copy(alpha = if (active) 0.45f else 0.22f)
    return this
        .clip(CircleShape)
        .background(fill, CircleShape)
        .border(0.9.dp, stroke, CircleShape)
}

fun Modifier.liquidGlassCircle(tinted: Boolean = false, active: Boolean = false): Modifier =
    liquidGlassCapsule(tinted = tinted, active = active)

fun Modifier.liquidGlassCard(cornerRadius: Dp = 22.dp, tinted: Boolean = false): Modifier {
    val shape = RoundedCornerShape(cornerRadius)
    val fill = if (tinted) Color(0xFF380F1F).copy(alpha = 0.56f) else Color.White.copy(alpha = 0.08f)
    return this
        .clip(shape)
        .background(fill, shape)
        .border(0.9.dp, Color.White.copy(alpha = 0.22f), shape)
}

fun Modifier.liquidGlassBackground(tinted: Boolean = false): Modifier {
    val bgBrush = if (tinted) {
        Brush.verticalGradient(
            listOf(
                Color(0xFF210812),
                Color(0xFF100409)
            )
        )
    } else {
        Brush.verticalGradient(
            listOf(
                Color(0xFF120A0F),
                Color(0xFF060205)
            )
        )
    }
    return this.background(bgBrush)
}

@Composable
fun BrandLogoX(size: Dp = 26.dp, active: Boolean = false, connected: Boolean = false) {
    Box(modifier = Modifier.size(size)) {
        Box(
            modifier = Modifier
                .size(size)
                .clip(CircleShape)
                .background(if (active) Color.White else Color.Black.copy(alpha = 0.58f))
                .border(
                    width = if (active) 1.5.dp else 0.8.dp,
                    color = if (active) Color.White else Color.White.copy(alpha = 0.28f),
                    shape = CircleShape
                )
                .alpha(if (active) 1f else 0.90f),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = "𝕏",
                color = if (active) Color.Black else Color.White,
                fontSize = (size.value * 0.54f).sp,
                fontWeight = FontWeight.Black
            )
        }
        if (connected) {
            Box(
                modifier = Modifier
                    .size(7.dp)
                    .align(Alignment.TopEnd)
                    .offset(x = 1.dp, y = (-1).dp)
                    .clip(CircleShape)
                    .background(Theme.accentBright)
                    .border(1.dp, Color.Black, CircleShape)
            )
        }
    }
}

@Composable
fun BrandLogoRule34(size: Dp = 26.dp, active: Boolean = false) {
    val shape = RoundedCornerShape((size.value * 0.28f).dp)
    Box(
        modifier = Modifier
            .size(size)
            .clip(shape)
            .background(Brush.linearGradient(listOf(Color(0xFFB0EBA6), Color(0xFF73C46B))))
            .border(
                width = if (active) 1.6.dp else 0.8.dp,
                color = if (active) Color.White else Color.White.copy(alpha = 0.28f),
                shape = shape
            )
            .alpha(if (active) 1f else 0.90f),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = "34",
            color = Color(0xFF0F380F),
            fontSize = (size.value * 0.45f).sp,
            fontWeight = FontWeight.Black
        )
    }
}

@Composable
fun BrandLogoInstagram(size: Dp = 26.dp, active: Boolean = false, connected: Boolean = false) {
    val shape = RoundedCornerShape((size.value * 0.28f).dp)
    Box(modifier = Modifier.size(size)) {
        Box(
            modifier = Modifier
                .size(size)
                .clip(shape)
                .background(
                    Brush.linearGradient(
                        listOf(
                            Color(0xFFFCC247),
                            Color(0xFFF54557),
                            Color(0xFFC229A6),
                            Color(0xFF613DE0)
                        )
                    )
                )
                .border(
                    width = if (active) 1.6.dp else 0.8.dp,
                    color = if (active) Color.White else Color.White.copy(alpha = 0.28f),
                    shape = shape
                )
                .alpha(if (active) 1f else 0.90f),
            contentAlignment = Alignment.Center
        ) {
            Canvas(modifier = Modifier.size(size * 0.58f)) {
                val stroke = Stroke(width = this.size.minDimension * 0.13f)
                drawRoundRect(
                    color = Color.White,
                    topLeft = Offset(this.size.width * 0.08f, this.size.height * 0.08f),
                    size = Size(this.size.width * 0.84f, this.size.height * 0.84f),
                    cornerRadius = CornerRadius(this.size.minDimension * 0.26f),
                    style = stroke
                )
                drawCircle(
                    color = Color.White,
                    radius = this.size.minDimension * 0.21f,
                    center = Offset(this.size.width * 0.5f, this.size.height * 0.5f),
                    style = stroke
                )
                drawCircle(
                    color = Color.White,
                    radius = this.size.minDimension * 0.07f,
                    center = Offset(this.size.width * 0.74f, this.size.height * 0.26f)
                )
            }
        }
        if (connected) {
            Box(
                modifier = Modifier
                    .size(7.dp)
                    .align(Alignment.TopEnd)
                    .offset(x = 1.dp, y = (-1).dp)
                    .clip(CircleShape)
                    .background(Theme.accentBright)
                    .border(1.dp, Color.Black, CircleShape)
            )
        }
    }
}

@Composable
fun BrandLogoErome(size: Dp = 26.dp, active: Boolean = false) {
    val shape = RoundedCornerShape((size.value * 0.28f).dp)
    Box(
        modifier = Modifier
            .size(size)
            .clip(shape)
            .background(Brush.linearGradient(listOf(Color(0xFFF03D8F), Color(0xFFA3246B))))
            .border(
                width = if (active) 1.6.dp else 0.8.dp,
                color = if (active) Color.White else Color.White.copy(alpha = 0.28f),
                shape = shape
            )
            .alpha(if (active) 1f else 0.90f),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = "E",
            color = Color.White,
            fontSize = (size.value * 0.54f).sp,
            fontWeight = FontWeight.Black
        )
    }
}

@Composable
fun BrandLogoLongVideos(size: Dp = 26.dp, active: Boolean = false) {
    val shape = RoundedCornerShape((size.value * 0.28f).dp)
    Box(
        modifier = Modifier
            .size(size)
            .clip(shape)
            .background(Brush.linearGradient(listOf(Color(0xFFFF8F24), Color(0xFFE63D70))))
            .border(
                width = if (active) 1.6.dp else 0.8.dp,
                color = if (active) Color.White else Color.White.copy(alpha = 0.28f),
                shape = shape
            )
            .alpha(if (active) 1f else 0.90f),
        contentAlignment = Alignment.Center
    ) {
        Icon(
            imageVector = Icons.Default.PlayArrow,
            contentDescription = "Long Videos",
            tint = Color.White,
            modifier = Modifier.size(size * 0.64f)
        )
    }
}

@Composable
fun BrandLogoOnlyFans(size: Dp = 26.dp, active: Boolean = false) {
    Box(
        modifier = Modifier
            .size(size)
            .clip(CircleShape)
            .background(Brush.linearGradient(listOf(Color(0xFF00B8F5), Color(0xFF0085D6))))
            .border(
                width = if (active) 1.6.dp else 0.8.dp,
                color = if (active) Color.White else Color.White.copy(alpha = 0.28f),
                shape = CircleShape
            )
            .alpha(if (active) 1f else 0.90f),
        contentAlignment = Alignment.Center
    ) {
        Text(
            text = "OF",
            color = Color.White,
            fontSize = (size.value * 0.42f).sp,
            fontWeight = FontWeight.Black
        )
    }
}

@Composable
fun ShimmerPlaceholder(modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "shimmer")
    val alpha = transition.animateFloat(
        initialValue = 0.08f,
        targetValue = 0.20f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 900, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "shimmerAlpha"
    )
    Box(modifier = modifier.background(Color(0xFF2B101C).copy(alpha = 0.6f + alpha.value)))
}

@Serializable
data class GoonedCategory(
    val name: String,
    val subscribers: Int,
    val subreddits: List<String>
) {
    val id: String get() = name
    val displayName: String
        get() = when (name) {
            "BigTits" -> "Big Tits"
            "Rule34" -> "Rule 34"
            else -> name
        }

    companion object {
        val featuredNames = listOf("Gooning", "TikTok", "OnlyFans", "Snapchat")

        val defaultCategories = listOf(
            GoonedCategory("Gooning", 7_834_580, listOf("GOONED", "pornrelapsed", "PORNism", "PornIsCheating")),
            GoonedCategory("TikTok", 8_886_694, listOf("tiktokthots", "tiktokporn", "tiktoknsfw", "TikTok_Ass", "TikTok_Tits")),
            GoonedCategory("OnlyFans", 5_433_860, listOf("OnlyFans101", "Slutsofonlyfans", "onlyfanshottest", "onlyfans_blessed", "onlyfans_wild")),
            GoonedCategory("Snapchat", 2_908_652, listOf("slutsofsnapchat", "NSFW_Snapchat")),
            GoonedCategory("Ahegao", 2_911_729, listOf("RealAhegao", "Ahegao_IRL", "AhegaoGirls", "Ahegaos", "AhegaoHardcore")),
            GoonedCategory("Amateur", 14_945_068, listOf("RealGirls", "homemadexxx", "OnOff", "gonewild", "Amateur")),
            GoonedCategory("Anal", 5_254_238, listOf("AnalGW", "analgonewild", "anal_gifs", "upherbutt", "buttsex")),
            GoonedCategory("Asian", 9_708_194, listOf("AsiansGoneWild", "AsianHotties", "bustyasians", "NSFW_Japan", "AsianCumsluts")),
            GoonedCategory("Ass", 11_378_541, listOf("ass", "bigasses", "booty", "twerking", "pawg")),
            GoonedCategory("BBW", 3_450_607, listOf("chubby", "BBWHardcore", "BBWVideos")),
            GoonedCategory("BDSM", 5_481_168, listOf("SheLikesItRough", "bdsm", "BDSMGW", "Dominated", "Spanking")),
            GoonedCategory("BigTits", 10_623_705, listOf("TittyDrop", "boobbounce", "boobs", "Stacked", "Boobies")),
            GoonedCategory("Bimbo", 2_368_502, listOf("bimbofetish", "BimboCumsluts", "bimbo", "EnhancedFucktoys", "BimboLovers")),
            GoonedCategory("Blowjob", 10_519_362, listOf("Blowjobs", "GirlsFinishingTheJob", "deepthroat", "FaceFuck", "gawkgawkgawk")),
            GoonedCategory("Cosplay", 6_591_046, listOf("cosplaygirls", "nsfwcosplay", "cosplaybabes", "CosplayPornVideos", "CosplayLewd")),
            GoonedCategory("Creampie", 1_959_609, listOf("CreamPieFlowingOut", "Breeding_her", "BreedMeDaddy")),
            GoonedCategory("Cuckold", 6_949_714, listOf("Cuckold", "HotwifeCuckolds", "Hotwife", "wifesharing", "WouldYouFuckMyWife")),
            GoonedCategory("Cumshot", 10_061_699, listOf("cumsluts", "cumshots", "facials", "coveredincum", "creampies")),
            GoonedCategory("Curvy", 8_816_287, listOf("MassiveTitsNAss", "SlimThick", "ThickWhiteGirls", "thick", "curvy")),
            GoonedCategory("Ebony", 5_906_600, listOf("BBCParadise", "EbonyHomemade", "EbonyThroatQueens", "BlackTittyWorld", "EbonyCuties")),
            GoonedCategory("Feet", 3_651_481, listOf("feetfuckers", "Feet_NSFW", "FeetInYourFace", "VIPFeet", "ButtsAndBareFeet")),
            GoonedCategory("Femboy", 3_133_290, listOf("Sissies", "StraightToSissy", "trapsgonewild")),
            GoonedCategory("Femdom", 3_372_328, listOf("Femdom", "FuckingMachines", "facesitting", "pegging", "strapon")),
            GoonedCategory("Fisting", 1_474_341, listOf("Fisting", "gape", "pussystretching")),
            GoonedCategory("Gangbang", 1_360_401, listOf("gangbang", "groupsex_gw", "GroupSexNSFW")),
            GoonedCategory("Gay", 2_527_557, listOf("gayporn", "MalesMasturbating", "GaybrosGoneWild")),
            GoonedCategory("Goth", 7_686_633, listOf("bigtiddygothgf", "gothsluts", "altgonewild", "gothgirlsgw", "suicidegirls")),
            GoonedCategory("Handjob", 1_344_247, listOf("Handjob", "FemdomHandjob", "EliteHandjob")),
            GoonedCategory("Hardcore", 11_145_695, listOf("HardcoreNSFW", "nsfwhardcore", "RoughPorn", "freeuse", "BreedingMaterial")),
            GoonedCategory("Hentai", 8_596_507, listOf("hentai", "HENTAI_GIF", "doujinshi", "Hentai__videos", "Tentai")),
            GoonedCategory("Indian", 2_491_611, listOf("IndiansGoneWild", "IndianHotwife", "desiindiansex")),
            GoonedCategory("Interracial", 3_282_794, listOf("blackchickswhitedicks", "blacked", "BLACKEDPawgs")),
            GoonedCategory("Latina", 5_952_742, listOf("LatinaCuties", "mexicana", "latinchickswhitedicks", "latinas", "Delicias_do_Brasil")),
            GoonedCategory("Lesbian", 5_628_522, listOf("girlskissing", "lesbians", "GirlsWithGirls", "Lesbian_gifs", "CuteLesbians")),
            GoonedCategory("MILF", 7_335_454, listOf("milf", "maturemilf", "MILFs", "gonewild30plus", "realmoms")),
            GoonedCategory("Petite", 12_520_619, listOf("BustyPetite", "PetiteGoneWild", "adorableporn", "LipsThatGrip", "petite")),
            GoonedCategory("POV", 2_197_024, listOf("CheatingPOV", "femalepov", "DoggyStylePOV")),
            GoonedCategory("Public", 8_310_431, listOf("PublicSexPorn", "PublicFlashing", "workgonewild", "Upskirt", "public")),
            GoonedCategory("Pussy", 8_451_811, listOf("grool", "rearpussy", "Innies", "pussy", "Pussy_Perfection")),
            GoonedCategory("Redheads", 2_129_486, listOf("GingerBeauties", "PetiteGingers", "RedheadMILFs", "RedheadsPorn", "redheads")),
            GoonedCategory("Rule34", 5_579_189, listOf("rule34", "FutanariGifs", "Overwatch_Porn")),
            GoonedCategory("Sluts", 7_161_572, listOf("Slut", "sluts", "needysluts")),
            GoonedCategory("Solo", 5_415_854, listOf("gettingherselfoff", "Orgasms", "orgasmcontrol", "jilling", "fingering")),
            GoonedCategory("Squirt", 3_222_102, listOf("Squirting", "Oilporn", "WetOil")),
            GoonedCategory("Teen", 11_487_517, listOf("LegalTeens", "barelylegalteens", "18_19", "TeenBeauties", "CollegeAmateurs")),
            GoonedCategory("Threesome", 2_284_337, listOf("Threesome", "threesomesNSFW", "ThreesomeGW")),
            GoonedCategory("Toys", 2_247_175, listOf("dildo", "HugeDildos", "ToysGW")),
            GoonedCategory("Trans", 8_245_889, listOf("traps", "FemBoys", "transporn", "Tgirls", "GoneWildTrans")),
            GoonedCategory("Videos", 8_023_026, listOf("NSFW_GIF", "nsfw_gifs", "porninfifteenseconds")),
            GoonedCategory("Vintage", 502_444, listOf("VintageBabes", "VintageSmut"))
        )
    }
}
