package com.pirsumoto.app

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.graphics.Path
import android.graphics.Rect
import android.os.Bundle
import android.view.ViewConfiguration
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.util.Log
import kotlin.math.max
import kotlin.math.min

class PirsumotoAccessibilityService : AccessibilityService() {

    companion object {
        var instance: PirsumotoAccessibilityService? = null
            private set
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        Log.d("A11Y", "Accessibility Service Connected")
        instance = this
    }

    override fun onUnbind(intent: Intent?): Boolean {
        Log.d("A11Y", "Accessibility Service Unbound")
        instance = null
        return super.onUnbind(intent)
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // We only use the service for querying, not event listening
    }

    override fun onInterrupt() {
        // Required, but not used here
    }

    data class Match(
        val node: AccessibilityNodeInfo,
        val label: String,
        val bounds: Rect,
        val score: Double
    )

    fun normalizeHebrew(s: String): String {
        return s
            .replace(Regex("[\\u0591-\\u05C7]"), "") // Hebrew niqqud/cantillation
            .replace(Regex("\\s+"), " ")
            .trim()
    }

    private fun getLevenshteinDistance(s1: String, s2: String): Int {
        if (s1 == s2) return 0
        if (s1.isEmpty()) return s2.length
        if (s2.isEmpty()) return s1.length

        var v0 = IntArray(s2.length + 1) { it }
        var v1 = IntArray(s2.length + 1)

        for (i in 0 until s1.length) {
            v1[0] = i + 1
            for (j in 0 until s2.length) {
                val cost = if (s1[i] == s2[j]) 0 else 1
                v1[j + 1] = minOf(v1[j] + 1, v0[j + 1] + 1, v0[j] + cost)
            }
            val temp = v0
            v0 = v1
            v1 = temp
        }
        return v0[s2.length]
    }

    private fun similarity(s1: String, s2: String): Double {
        if (s1.isEmpty() && s2.isEmpty()) return 1.0
        if (s1.isEmpty() || s2.isEmpty()) return 0.0

        // Allow exact matches or substrings with high scores
        if (s1 == s2) return 1.0

        // Match exact text ignoring whitespace (e.g. "השכרה/החכר" vs "השכרה / החכר")
        val clean1 = s1.replace("\\s".toRegex(), "")
        val clean2 = s2.replace("\\s".toRegex(), "")
        if (clean1.isNotEmpty() && clean1 == clean2) return 1.0

        if (s1.contains(s2) || s2.contains(s1)) return 0.95

        // Fast fail: if length difference is too big, it won't meet the threshold
        val maxLength = max(s1.length, s2.length)
        val minLength = min(s1.length, s2.length)
        if (minLength.toDouble() / maxLength < 0.5) return 0.0

        val distance = getLevenshteinDistance(s1, s2)
        return 1.0 - (distance.toDouble() / maxLength.toDouble())
    }

    private fun evaluateNodeForMatch(
        node: AccessibilityNodeInfo,
        normalizedTargetList: List<String>,
        threshold: Double,
        matches: MutableList<Match>
    ) {
        val labels = listOfNotNull(
            node.text?.toString(),
            node.contentDescription?.toString()
        )

        for (label in labels) {
            val normalizedLabel = normalizeHebrew(label)
            var bestScore = 0.0
            for (normalizedTarget in normalizedTargetList) {
                val score = similarity(normalizedLabel, normalizedTarget)
                if (score > bestScore) {
                    bestScore = score
                }
            }

            if (bestScore >= threshold) {
                val rect = Rect()
                node.getBoundsInScreen(rect)

                // Avoid duplicate coordinates
                val isDuplicate = matches.any { 
                    Math.abs(it.bounds.centerX() - rect.centerX()) < 25 &&
                    Math.abs(it.bounds.centerY() - rect.centerY()) < 25 
                }

                if (!isDuplicate) {
                    matches.add(
                        Match(
                            node = node,
                            label = label,
                            bounds = rect,
                            score = bestScore
                        )
                    )
                }
            }
        }
    }

    fun findBestHebrewMatches(
        root: AccessibilityNodeInfo?,
        target: String,
        threshold: Double = 0.82
    ): List<Match> {
        if (root == null) return emptyList()

        val normalizedTargetList = target.split("|").map { normalizeHebrew(it) }
        val matches = mutableListOf<Match>()

        // FAST PATH: Use Android's built-in fast search first
        val candidates = mutableSetOf<AccessibilityNodeInfo>()
        for (normalizedTarget in normalizedTargetList) {
            val longestWord = normalizedTarget.split(" ").maxByOrNull { it.length } ?: normalizedTarget
            if (longestWord.isNotEmpty()) {
                val foundNodes = root.findAccessibilityNodeInfosByText(longestWord)
                if (foundNodes != null) {
                    candidates.addAll(foundNodes)
                }
            }
        }

        for (node in candidates) {
            evaluateNodeForMatch(node, normalizedTargetList, threshold, matches)
        }

        // If fast path found matches, return immediately to save full tree traversal
        if (matches.isNotEmpty()) {
            matches.sortByDescending { it.score }
            return matches
        }

        // FALLBACK: Full traversal only if fast search missed (e.g. due to Niqqud or complex DOM)
        fun visit(node: AccessibilityNodeInfo) {
            evaluateNodeForMatch(node, normalizedTargetList, threshold, matches)

            for (i in 0 until node.childCount) {
                node.getChild(i)?.let { child ->
                    visit(child)
                }
            }
        }

        visit(root)
        // Sort matches by descending score
        matches.sortByDescending { it.score }
        return matches
    }

    fun findInputBeforeTarget(
        root: AccessibilityNodeInfo?,
        target: String,
        targetInstance: Int = 1,
        threshold: Double = 0.82
    ): Rect? {
        if (root == null) return null

        val normalizedTargetList = target.split("|").map { normalizeHebrew(it) }
        
        data class TargetMatch(val match: Match, val precedingInput: Rect?)
        val allMatches = mutableListOf<TargetMatch>()
        
        var lastInputRect: Rect? = null

        fun visit(node: AccessibilityNodeInfo) {
            // Check if this node is editable or is an EditText
            if (node.isEditable || node.className?.toString()?.contains("EditText") == true) {
                val rect = Rect()
                node.getBoundsInScreen(rect)
                lastInputRect = rect
            }

            val labels = listOfNotNull(
                node.text?.toString(),
                node.contentDescription?.toString()
            )

            for (label in labels) {
                val normalizedLabel = normalizeHebrew(label)
                var bestScore = 0.0
                for (normalizedTarget in normalizedTargetList) {
                    val score = similarity(normalizedLabel, normalizedTarget)
                    if (score > bestScore) {
                        bestScore = score
                    }
                }

                if (bestScore >= threshold) {
                    val rect = Rect()
                    node.getBoundsInScreen(rect)

                    // Avoid duplicate coordinates
                    val isDuplicate = allMatches.any { 
                        Math.abs(it.match.bounds.centerX() - rect.centerX()) < 25 &&
                        Math.abs(it.match.bounds.centerY() - rect.centerY()) < 25 
                    }

                    if (!isDuplicate) {
                        allMatches.add(
                            TargetMatch(
                                match = Match(node = node, label = label, bounds = rect, score = bestScore),
                                precedingInput = lastInputRect
                            )
                        )
                    }
                }
            }

            for (i in 0 until node.childCount) {
                node.getChild(i)?.let { child ->
                    visit(child)
                }
            }
        }

        visit(root)
        
        val sortedMatches = allMatches.sortedByDescending { it.match.score }
        
        if (sortedMatches.size >= targetInstance) {
            return sortedMatches[targetInstance - 1].precedingInput
        }
        return null
    }

    fun findNodeBeforeTarget(
        root: AccessibilityNodeInfo?,
        target: String,
        targetInstance: Int = 1,
        threshold: Double = 0.82
    ): Rect? {
        if (root == null) return null

        val normalizedTargetList = target.split("|").map { normalizeHebrew(it) }
        
        data class TargetMatch(val match: Match, val precedingNode: Rect?)
        val allMatches = mutableListOf<TargetMatch>()
        
        var lastMeaningfulRect: Rect? = null

        fun visit(node: AccessibilityNodeInfo) {
            val labels = listOfNotNull(
                node.text?.toString(),
                node.contentDescription?.toString()
            )

            var isTarget = false
            for (label in labels) {
                val normalizedLabel = normalizeHebrew(label)
                var bestScore = 0.0
                for (normalizedTarget in normalizedTargetList) {
                    val score = similarity(normalizedLabel, normalizedTarget)
                    if (score > bestScore) {
                        bestScore = score
                    }
                }

                if (bestScore >= threshold) {
                    val rect = Rect()
                    node.getBoundsInScreen(rect)

                    val isDuplicate = allMatches.any { 
                        Math.abs(it.match.bounds.centerX() - rect.centerX()) < 25 &&
                        Math.abs(it.match.bounds.centerY() - rect.centerY()) < 25 
                    }

                    if (!isDuplicate) {
                        allMatches.add(
                            TargetMatch(
                                match = Match(node = node, label = label, bounds = rect, score = bestScore),
                                precedingNode = lastMeaningfulRect
                            )
                        )
                    }
                    isTarget = true
                    break
                }
            }

            if (!isTarget) {
                val hasText = !node.text.isNullOrEmpty() || !node.contentDescription.isNullOrEmpty()
                val isTextView = node.className?.toString()?.contains("TextView") == true
                if (hasText || isTextView || node.isClickable) {
                    val rect = Rect()
                    node.getBoundsInScreen(rect)
                    lastMeaningfulRect = rect
                }
            }

            for (i in 0 until node.childCount) {
                node.getChild(i)?.let { child ->
                    visit(child)
                }
            }
        }

        visit(root)
        
        val sortedMatches = allMatches.sortedByDescending { it.match.score }
        
        if (sortedMatches.size >= targetInstance) {
            return sortedMatches[targetInstance - 1].precedingNode
        }
        return null
    }

    fun findNodeAfterTarget(
        root: AccessibilityNodeInfo?,
        target: String,
        targetInstance: Int = 1,
        threshold: Double = 0.82,
        offset: Int = 1
    ): Rect? {
        if (root == null) return null

        val normalizedTargetList = target.split("|").map { normalizeHebrew(it) }
        
        val allNodes = mutableListOf<AccessibilityNodeInfo>()
        fun visitAndCollect(node: AccessibilityNodeInfo) {
            allNodes.add(node)
            for (i in 0 until node.childCount) {
                node.getChild(i)?.let { visitAndCollect(it) }
            }
        }
        visitAndCollect(root)

        data class TargetMatch(val match: Match, val nodeIndex: Int)
        val allMatches = mutableListOf<TargetMatch>()

        for ((index, node) in allNodes.withIndex()) {
            val labels = listOfNotNull(
                node.text?.toString(),
                node.contentDescription?.toString()
            )

            for (label in labels) {
                val normalizedLabel = normalizeHebrew(label)
                var bestScore = 0.0
                for (normalizedTarget in normalizedTargetList) {
                    val score = similarity(normalizedLabel, normalizedTarget)
                    if (score > bestScore) {
                        bestScore = score
                    }
                }

                if (bestScore >= threshold) {
                    val rect = Rect()
                    node.getBoundsInScreen(rect)

                    val isDuplicate = allMatches.any { 
                        Math.abs(it.match.bounds.centerX() - rect.centerX()) < 25 &&
                        Math.abs(it.match.bounds.centerY() - rect.centerY()) < 25 
                    }

                    if (!isDuplicate) {
                        allMatches.add(
                            TargetMatch(
                                match = Match(node = node, label = label, bounds = rect, score = bestScore),
                                nodeIndex = index
                            )
                        )
                    }
                    break
                }
            }
        }

        val sortedMatches = allMatches.sortedByDescending { it.match.score }
        
        if (sortedMatches.size >= targetInstance) {
            val targetMatch = sortedMatches[targetInstance - 1]
            var currentOffset = 0
            for (i in (targetMatch.nodeIndex + 1) until allNodes.size) {
                val node = allNodes[i]
                val hasText = !node.text.isNullOrEmpty() || !node.contentDescription.isNullOrEmpty()
                val isTextView = node.className?.toString()?.contains("TextView") == true
                val isEditText = node.className?.toString()?.contains("EditText") == true
                if (hasText || isTextView || isEditText || node.isClickable || node.isEditable) {
                    currentOffset++
                    if (currentOffset == offset) {
                        val rect = Rect()
                        node.getBoundsInScreen(rect)
                        return rect
                    }
                }
            }
        }
        return null
    }

    fun findNodeTextAfterTarget(
        root: AccessibilityNodeInfo?,
        target: String,
        targetInstance: Int = 1,
        threshold: Double = 0.82,
        offset: Int = 1
    ): String? {
        if (root == null) return null

        val normalizedTargetList = target.split("|").map { normalizeHebrew(it) }
        
        val allNodes = mutableListOf<AccessibilityNodeInfo>()
        fun visitAndCollect(node: AccessibilityNodeInfo) {
            allNodes.add(node)
            for (i in 0 until node.childCount) {
                node.getChild(i)?.let { visitAndCollect(it) }
            }
        }
        visitAndCollect(root)

        data class TargetMatch(val match: Match, val nodeIndex: Int)
        val allMatches = mutableListOf<TargetMatch>()

        for ((index, node) in allNodes.withIndex()) {
            val labels = listOfNotNull(
                node.text?.toString(),
                node.contentDescription?.toString()
            )

            for (label in labels) {
                val normalizedLabel = normalizeHebrew(label)
                var bestScore = 0.0
                for (normalizedTarget in normalizedTargetList) {
                    val score = similarity(normalizedLabel, normalizedTarget)
                    if (score > bestScore) {
                        bestScore = score
                    }
                }

                if (bestScore >= threshold) {
                    val rect = Rect()
                    node.getBoundsInScreen(rect)

                    val isDuplicate = allMatches.any { 
                        Math.abs(it.match.bounds.centerX() - rect.centerX()) < 25 &&
                        Math.abs(it.match.bounds.centerY() - rect.centerY()) < 25 
                    }

                    if (!isDuplicate) {
                        allMatches.add(
                            TargetMatch(
                                match = Match(node = node, label = label, bounds = rect, score = bestScore),
                                nodeIndex = index
                            )
                        )
                    }
                    break
                }
            }
        }

        val sortedMatches = allMatches.sortedByDescending { it.match.score }
        
        if (sortedMatches.size >= targetInstance) {
            val targetMatch = sortedMatches[targetInstance - 1]
            var currentOffset = 0
            for (i in (targetMatch.nodeIndex + 1) until allNodes.size) {
                val node = allNodes[i]
                val hasText = !node.text.isNullOrEmpty() || !node.contentDescription.isNullOrEmpty()
                val isTextView = node.className?.toString()?.contains("TextView") == true
                val isEditText = node.className?.toString()?.contains("EditText") == true
                if (hasText || isTextView || isEditText || node.isClickable || node.isEditable) {
                    currentOffset++
                    if (currentOffset == offset) {
                        return node.text?.toString() ?: node.contentDescription?.toString() ?: ""
                    }
                }
            }
        }
        return null
    }

    fun findClickableAncestor(node: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        var current: AccessibilityNodeInfo? = node
        while (current != null) {
            if (current.isClickable) return current
            current = current.parent
        }
        return null
    }

    fun clickNode(node: AccessibilityNodeInfo): Boolean {
        return node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
    }

    fun tapBounds(rect: Rect) {
        val x = rect.centerX().toFloat()
        val y = rect.centerY().toFloat()

        // WebViews often ignore zero-length gesture paths. 
        // We create a tiny 1-pixel movement to ensure it registers as a real touch.
        val path = Path().apply {
            moveTo(x, y)
            lineTo(x + 1f, y + 1f)
        }

        val gesture = GestureDescription.Builder()
            .addStroke(
                GestureDescription.StrokeDescription(
                    path,
                    0,
                    50L // 50ms is a safe, standard tap duration
                )
            )
            .build()

        dispatchGesture(gesture, null, null)
    }

    fun swipe(startX: Float, startY: Float, endX: Float, endY: Float, duration: Long = 300L): Boolean {
        val path = Path().apply {
            moveTo(startX, startY)
            lineTo(endX, endY)
        }

        val gesture = GestureDescription.Builder()
            .addStroke(
                GestureDescription.StrokeDescription(
                    path,
                    0,
                    duration
                )
            )
            .build()

        return dispatchGesture(gesture, null, null)
    }

    fun enterTextIntoNode(node: AccessibilityNodeInfo, text: String): Boolean {
        val arguments = Bundle()
        arguments.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, arguments)
    }

    fun scrollNode(node: AccessibilityNodeInfo, percent: Double): Boolean {
        // Just perform a general scroll forward on the node or its scrollable ancestor
        var current: AccessibilityNodeInfo? = node
        while (current != null) {
            if (current.isScrollable) {
                return current.performAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD)
            }
            current = current.parent
        }
        return false
    }

    fun logTree(root: AccessibilityNodeInfo?) {
        val str = getTreeString(root)
        val maxLogSize = 3000
        for (i in 0..str.length / maxLogSize) {
            val start = i * maxLogSize
            var end = (i + 1) * maxLogSize
            if (end > str.length) end = str.length
            if (start < end) {
                Log.d("A11Y_TREE", str.substring(start, end))
            }
        }
    }

    fun getTreeString(root: AccessibilityNodeInfo?): String {
        if (root == null) return "Root is null"
        val sb = java.lang.StringBuilder()
        sb.append("--- Accessibility Tree Dump ---\n")
        fun traverse(node: AccessibilityNodeInfo, depth: Int) {
            val indent = "  ".repeat(depth)
            val text = node.text?.toString() ?: ""
            val desc = node.contentDescription?.toString() ?: ""
            val className = node.className?.toString() ?: ""
            val isClickable = node.isClickable
            
            val bounds = Rect()
            node.getBoundsInScreen(bounds)
            
            sb.append("$indent[$className] text=\"$text\" desc=\"$desc\" clickable=$isClickable bounds=$bounds\n")

            for (i in 0 until node.childCount) {
                node.getChild(i)?.let { traverse(it, depth + 1) }
            }
        }
        traverse(root, 0)
        sb.append("--- End of Tree ---")
        return sb.toString()
    }
}
