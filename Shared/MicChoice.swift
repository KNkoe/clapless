/// Which microphone is used: the chosen one while it is there, otherwise the Mac's own default.
enum MicChoice {
    struct Candidate: Equatable {
        var id: String
        var builtIn: Bool
    }

    /// `chosen` nil means "whatever the Mac is set to". `systemDefault` may name a microphone that
    /// is not offered (an iPhone), in which case the built-in one stands in. Nil when there is none.
    static func pick(chosen: String?, systemDefault: String?, among: [Candidate]) -> String? {
        for wanted in [chosen, systemDefault] {
            if let wanted, among.contains(where: { $0.id == wanted }) { return wanted }
        }
        return (among.first { $0.builtIn } ?? among.first)?.id
    }

    /// During a take the microphone in use is kept for as long as it is there, even if the chosen
    /// one comes back: every change puts a join in the sound.
    static func pickDuringTake(current: String?, chosen: String?, systemDefault: String?,
                               among: [Candidate]) -> String? {
        if let current, among.contains(where: { $0.id == current }) { return current }
        return pick(chosen: chosen, systemDefault: systemDefault, among: among)
    }
}
