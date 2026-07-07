import Foundation

/// Lightweight localization for Waylo's OWN strings (panel labels, status
/// lines, spoken phrases), keyed off the user's LanguagePreference — the same
/// switch that drives STT/TTS, so flipping to हिन्दी localizes the whole
/// experience at once. Step instructions arrive already localized from the
/// backend; this covers everything Waylo says around them.
///
/// Missing keys fall back to English, so partially-translated languages
/// degrade gracefully instead of showing raw keys.
enum L10n {

    static func t(_ key: String) -> String {
        let table: [String: String]
        switch LanguagePreference.current {
        case .english: table = en
        case .hindi: table = hi
        case .punjabi: table = pa
        }
        return table[key] ?? en[key] ?? key
    }

    /// "Step 2 of 5" in the current language.
    static func step(_ index: Int, _ total: Int) -> String {
        String(format: t("step_of"), index, total)
    }

    private static let en: [String: String] = [
        "ask_prompt": "What do you want to learn?",
        "start_guide": "Start Guide →",
        "generating": "Generating your guide...",
        "listening": "Listening… speak now",
        "back": "Back", "next": "Next", "pause": "Pause",
        "resume": "Resume", "done": "Done", "stop": "Stop",
        "step_of": "Step %d of %d",
        "click_highlight": " — click the highlighted spot to continue",
        "finding": "Finding it on screen...",
        "paused": "Paused",
        "manual_fallback": "I couldn't find it. Do it yourself, then press Next.",
        "spoken_done": "All done! You've completed the task.",
        "spoken_not_found": "I couldn't find that one. Please do it yourself, then press Next.",
        "spoken_going_back": "Going back.",
        "spoken_skipping": "Skipping ahead.",
        "spoken_again": "Here it is again.",
        "spoken_destructive": "This one deletes or changes things, so you click it yourself — I'll continue right after.",
        "task_complete": "Task complete! 🎉",
    ]

    private static let hi: [String: String] = [
        "ask_prompt": "आप क्या सीखना चाहते हैं?",
        "start_guide": "गाइड शुरू करें →",
        "generating": "आपकी गाइड बन रही है...",
        "listening": "सुन रहा हूँ… बोलिए",
        "back": "पीछे", "next": "आगे", "pause": "रोकें",
        "resume": "जारी रखें", "done": "हो गया", "stop": "बंद करें",
        "step_of": "चरण %d / %d",
        "click_highlight": " — आगे बढ़ने के लिए हाइलाइट की गई जगह पर क्लिक करें",
        "finding": "स्क्रीन पर ढूँढ रहा हूँ...",
        "paused": "रुका हुआ",
        "manual_fallback": "मुझे यह नहीं मिला। आप खुद कर लें, फिर 'आगे' दबाएँ।",
        "spoken_done": "बहुत बढ़िया! आपने काम पूरा कर लिया।",
        "spoken_not_found": "मुझे वह नहीं मिला। आप खुद कर लें, फिर आगे दबाएँ।",
        "spoken_going_back": "पीछे जा रहे हैं।",
        "spoken_skipping": "आगे बढ़ रहे हैं।",
        "spoken_again": "यह रहा, फिर से।",
        "spoken_destructive": "यह चीज़ें बदल या हटा देता है, इसलिए इसे आप खुद क्लिक करें — मैं उसके बाद आगे बढ़ूँगा।",
        "task_complete": "काम पूरा! 🎉",
    ]

    private static let pa: [String: String] = [
        "ask_prompt": "ਤੁਸੀਂ ਕੀ ਸਿੱਖਣਾ ਚਾਹੁੰਦੇ ਹੋ?",
        "start_guide": "ਗਾਈਡ ਸ਼ੁਰੂ ਕਰੋ →",
        "generating": "ਤੁਹਾਡੀ ਗਾਈਡ ਬਣ ਰਹੀ ਹੈ...",
        "listening": "ਸੁਣ ਰਿਹਾ ਹਾਂ… ਬੋਲੋ",
        "back": "ਪਿੱਛੇ", "next": "ਅੱਗੇ", "pause": "ਰੋਕੋ",
        "resume": "ਜਾਰੀ ਰੱਖੋ", "done": "ਹੋ ਗਿਆ", "stop": "ਬੰਦ ਕਰੋ",
        "step_of": "ਕਦਮ %d / %d",
        "click_highlight": " — ਅੱਗੇ ਵਧਣ ਲਈ ਹਾਈਲਾਈਟ ਕੀਤੀ ਥਾਂ 'ਤੇ ਕਲਿੱਕ ਕਰੋ",
        "finding": "ਸਕ੍ਰੀਨ 'ਤੇ ਲੱਭ ਰਿਹਾ ਹਾਂ...",
        "paused": "ਰੁਕਿਆ ਹੋਇਆ",
        "manual_fallback": "ਮੈਨੂੰ ਇਹ ਨਹੀਂ ਮਿਲਿਆ। ਤੁਸੀਂ ਆਪ ਕਰ ਲਵੋ, ਫਿਰ 'ਅੱਗੇ' ਦਬਾਓ।",
        "spoken_done": "ਬਹੁਤ ਵਧੀਆ! ਤੁਸੀਂ ਕੰਮ ਪੂਰਾ ਕਰ ਲਿਆ।",
        "spoken_not_found": "ਮੈਨੂੰ ਉਹ ਨਹੀਂ ਮਿਲਿਆ। ਤੁਸੀਂ ਆਪ ਕਰ ਲਵੋ, ਫਿਰ ਅੱਗੇ ਦਬਾਓ।",
        "spoken_going_back": "ਪਿੱਛੇ ਜਾ ਰਹੇ ਹਾਂ।",
        "spoken_skipping": "ਅੱਗੇ ਵਧ ਰਹੇ ਹਾਂ।",
        "spoken_again": "ਇਹ ਰਿਹਾ, ਫਿਰ ਤੋਂ।",
        "spoken_destructive": "ਇਹ ਚੀਜ਼ਾਂ ਬਦਲ ਜਾਂ ਹਟਾ ਦਿੰਦਾ ਹੈ, ਇਸ ਲਈ ਇਸਨੂੰ ਤੁਸੀਂ ਆਪ ਕਲਿੱਕ ਕਰੋ — ਮੈਂ ਉਸ ਤੋਂ ਬਾਅਦ ਅੱਗੇ ਵਧਾਂਗਾ।",
        "task_complete": "ਕੰਮ ਪੂਰਾ! 🎉",
    ]
}
