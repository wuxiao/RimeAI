import Foundation
import SQLite3

/// Schema v2 DDL for the domain-lexicon tables, shared verbatim by
/// `PhraseBookStore` (schema owner, also bumps `user_version`) and
/// `DomainLexiconStore` (asset CRUD). Every statement is idempotent, so
/// both stores may run it against a database at any version.
enum LexiconSchema {
    static func install() -> [String] {
        [
            """
            CREATE TABLE IF NOT EXISTS lexicons (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                domain TEXT NOT NULL,
                version TEXT NOT NULL,
                entry_count INTEGER NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1,
                license TEXT NOT NULL DEFAULT '',
                attribution TEXT NOT NULL DEFAULT '',
                installed_at_ms INTEGER NOT NULL
            )
            """,
            """
            CREATE TABLE IF NOT EXISTS lexicon_entries (
                lexicon_id TEXT NOT NULL,
                text TEXT NOT NULL,
                pinyin_keys TEXT NOT NULL,
                weight INTEGER NOT NULL DEFAULT 50,
                blocked INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(lexicon_id, text, pinyin_keys)
            )
            """,
            """
            CREATE INDEX IF NOT EXISTS lexicon_entries_lookup
            ON lexicon_entries(lexicon_id, pinyin_keys)
            """,
        ]
    }
}
