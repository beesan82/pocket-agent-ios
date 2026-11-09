import Foundation

/// The experiment series E: passages the term dictionary was NOT built
/// from, added by ADR-049 and frozen on 2026-11-09, before any further
/// dictionary change. Passage C's 0.00% is scored on the very errors the
/// dictionary's four pairs were seeded from, so it cannot show whether
/// the dictionary generalizes; the E series is that yardstick.
///
/// E1/E2 use the four target terms (`TranscriptionTerms.targets`) in
/// contexts passage C does not, with kanji numerals so the ADR-046
/// numeral normalization is exercised too. E3 is the trap: it uses the
/// dictionary's misrecognition strings in their legitimate meanings, in
/// collocations that pass next to the guarded rules' followings without
/// matching them — any dictionary firing on E3 is over-correction, and
/// zero firings is its pass bar. E4 is a long everyday passage with no
/// listed terms (about 300 characters, for finer CER resolution). E5 is
/// dense in personal names, place names and katakana words.
///
/// Freeze rule (ADR-049): the texts never change to accommodate a
/// dictionary change. After a dictionary change, only the E series' CER
/// and firing counts are read. The synthesized readings ship with the app
/// like the A–C ones (ADR-044) and are scored by `ExperimentCheck` in the
/// app target; the journal ids are `E1`…`E5` so the series never mix.
public enum ExperimentPassage: String, CaseIterable, Sendable {
    case e1
    case e2
    case e3
    case e4
    case e5

    /// The journal and display id ("E1"…"E5").
    public var id: String {
        switch self {
        case .e1:
            return "E1"
        case .e2:
            return "E2"
        case .e3:
            return "E3"
        case .e4:
            return "E4"
        case .e5:
            return "E5"
        }
    }

    public var label: String {
        switch self {
        case .e1:
            return "E1 未見・専門用語（導入の効果）"
        case .e2:
            return "E2 未見・専門用語（検査の異常）"
        case .e3:
            return "E3 罠・企画の正当用法"
        case .e4:
            return "E4 日常文（長文）"
        case .e5:
            return "E5 固有名詞・カタカナ"
        }
    }

    public var text: String {
        switch self {
        case .e1:
            return "新しい露光装置が三台入ってから、線幅の管理が安定してきました。歩留まりは先月の八十八パーセントから九十二パーセントまで上がり、測定値が規格を超えるロットもほとんどなくなりました。"
        case .e2:
            return "昨日の検査では、線幅が規格の下限ぎりぎりのウェハが十二枚見つかりました。露光装置の焦点が少しずれていたことが原因で、歩留まりにも影響が出ています。今週中に対策を終えて、金曜日に三回目の検査を行います。"
        case .e3:
            return "今年の文化祭では、期待を超える企画を出すことができました。企画書の作成から当日の運営まで、企画会議を重ねて準備を進めてきました。来場者数は当初の見込みを超えて過去最高になり、企画の価値を改めて感じました。"
        case .e4:
            return "今朝は六時に目が覚めました。窓の外はよく晴れていて、洗濯物を干すのにちょうどいい天気です。朝ごはんに卵焼きと味噌汁を作って、食パンと一緒に食べました。食べ終わってから近所の公園まで散歩に出かけました。公園では犬を連れた人や、走っている人が何人かいました。帰りに商店街の八百屋で、トマトとキュウリとジャガイモを買いました。昼ごはんは昨日の残りのカレーにしようと思います。午後は部屋の掃除をして、本を読んでのんびり過ごす予定です。夕方になったら友達に電話をして、来週の旅行の相談をするつもりです。夜は早めにお風呂に入って、温かいお茶を飲みながらテレビを見るのが楽しみです。明日も晴れるといいなと思います。"
        case .e5:
            return "来週、大学時代の友人のサトウさんとマリアさんに会います。二人はカナダのバンクーバーから一時帰国中で、京都のホテルに泊まっています。待ち合わせは大阪駅の近くのカフェで、名物のパンケーキを食べながら、トロントでの暮らしや仕事の話を聞く予定です。帰りにデパートでチョコレートとコーヒー豆をお土産に買うつもりです。"
        }
    }

    /// Only E3: its text uses the dictionary's misrecognition strings in
    /// their legitimate meanings, so any firing on it is over-correction.
    public var isTrapPassage: Bool {
        self == .e3
    }
}
