import GRDB

enum Migrations {
    static let names = ["v1_profiles", "v2_sessions", "v3_history", "v4_bookmarks", "v5_downloads", "v6_permissions", "v7_daily_browsing", "v8_site_rule_timestamps", "v9_group_appearance", "v10_profile_identity", "v11_split_view", "v12_feeds", "v13_power_tools", "v14_ai_search_events"]
    static func make() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(names[0]) { db in
            try db.execute(sql: """
            CREATE TABLE profiles(id TEXT PRIMARY KEY, name TEXT NOT NULL, created_at REAL NOT NULL,
              website_store_id TEXT UNIQUE);
            """)
        }
        migrator.registerMigration(names[1]) { db in
            try db.execute(sql: """
            CREATE TABLE browser_sessions(id TEXT PRIMARY KEY, profile_id TEXT NOT NULL REFERENCES profiles(id), updated_at REAL NOT NULL);
            CREATE TABLE windows(id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES browser_sessions(id) ON DELETE CASCADE,
              selected_tab_id TEXT, frame TEXT, position INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE tab_groups(id TEXT PRIMARY KEY, window_id TEXT NOT NULL REFERENCES windows(id) ON DELETE CASCADE,
              name TEXT NOT NULL, collapsed INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL);
            CREATE TABLE tabs(id TEXT PRIMARY KEY, window_id TEXT NOT NULL REFERENCES windows(id) ON DELETE CASCADE,
              group_id TEXT REFERENCES tab_groups(id) ON DELETE SET NULL, url TEXT, title TEXT NOT NULL,
              pinned INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL);
            CREATE INDEX tabs_window_order ON tabs(window_id, position);
            CREATE TABLE recently_closed(id TEXT PRIMARY KEY, profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
              window_id TEXT NOT NULL, tab_id TEXT NOT NULL, url TEXT, title TEXT NOT NULL, pinned INTEGER NOT NULL,
              group_id TEXT, position INTEGER NOT NULL, closed_at REAL NOT NULL);
            CREATE INDEX recently_closed_profile ON recently_closed(profile_id, closed_at DESC);
            """)
        }
        migrator.registerMigration(names[2]) { db in
            try db.execute(sql: """
            CREATE TABLE history_pages(id INTEGER PRIMARY KEY, profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
              normalized_url TEXT NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL, host TEXT NOT NULL,
              first_seen REAL NOT NULL, last_seen REAL NOT NULL, visit_count INTEGER NOT NULL DEFAULT 0,
              UNIQUE(profile_id, normalized_url));
            CREATE TABLE history_visits(id INTEGER PRIMARY KEY, page_id INTEGER NOT NULL REFERENCES history_pages(id) ON DELETE CASCADE,
              profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE, visited_at REAL NOT NULL, transition TEXT);
            CREATE INDEX visits_profile_time ON history_visits(profile_id, visited_at DESC);
            CREATE INDEX history_host ON history_pages(profile_id, host);
            """)
        }
        migrator.registerMigration(names[3]) { db in
            try db.execute(sql: """
            CREATE TABLE bookmark_folders(id TEXT PRIMARY KEY, profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
              parent_id TEXT REFERENCES bookmark_folders(id) ON DELETE CASCADE, title TEXT NOT NULL, position INTEGER NOT NULL);
            CREATE TABLE bookmarks(id TEXT PRIMARY KEY, profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
              folder_id TEXT REFERENCES bookmark_folders(id) ON DELETE CASCADE, title TEXT NOT NULL, url TEXT NOT NULL,
              position INTEGER NOT NULL, created_at REAL NOT NULL);
            CREATE INDEX bookmarks_folder_order ON bookmarks(profile_id, folder_id, position);
            """)
        }
        migrator.registerMigration(names[4]) { db in
            try db.execute(sql: """
            CREATE TABLE downloads(id TEXT PRIMARY KEY, profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
              tab_id TEXT, url TEXT NOT NULL, filename TEXT NOT NULL, destination TEXT, bookmark BLOB,
              state TEXT NOT NULL, received INTEGER NOT NULL DEFAULT 0, expected INTEGER,
              error TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL);
            CREATE INDEX downloads_profile_time ON downloads(profile_id, created_at DESC);
            """)
        }
        migrator.registerMigration(names[5]) { db in
            try db.execute(sql: """
            CREATE TABLE permissions(profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
              origin TEXT NOT NULL, category TEXT NOT NULL, decision TEXT NOT NULL,
              PRIMARY KEY(profile_id, origin, category));
            """)
        }
        migrator.registerMigration(names[6]) { db in
            try db.execute(sql: """
            ALTER TABLE windows ADD COLUMN closed_at REAL;
            ALTER TABLE tabs ADD COLUMN sleeping INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE bookmarks ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0;
            ALTER TABLE permissions ADD COLUMN updated_at REAL NOT NULL DEFAULT 0;
            CREATE TABLE site_rules(profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
              origin TEXT NOT NULL, never_sleep INTEGER NOT NULL DEFAULT 0, muted INTEGER NOT NULL DEFAULT 0,
              PRIMARY KEY(profile_id,origin));
            CREATE TABLE protocol_decisions(profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
              origin TEXT NOT NULL, scheme TEXT NOT NULL, decision TEXT NOT NULL, updated_at REAL NOT NULL,
              PRIMARY KEY(profile_id,origin,scheme));
            CREATE INDEX visits_page_time ON history_visits(page_id,visited_at DESC,id DESC);
            CREATE INDEX folders_profile_parent ON bookmark_folders(profile_id,parent_id,position);
            """)
        }
        migrator.registerMigration(names[7]) { db in
            try db.execute(sql: "ALTER TABLE site_rules ADD COLUMN updated_at REAL NOT NULL DEFAULT 0")
        }
        migrator.registerMigration(names[8]) { db in
            try db.execute(sql: "ALTER TABLE tab_groups ADD COLUMN color TEXT; ALTER TABLE tab_groups ADD COLUMN anchor_index INTEGER;")
        }
        migrator.registerMigration(names[9]) { db in
            try db.execute(sql: "ALTER TABLE profiles ADD COLUMN color TEXT NOT NULL DEFAULT 'mint'; UPDATE profiles SET name='Personal' WHERE id='00000000-0000-0000-0000-000000000001' AND name='Default';")
        }
        migrator.registerMigration(names[10]) { db in
            try db.execute(sql: "ALTER TABLE windows ADD COLUMN split_left TEXT; ALTER TABLE windows ADD COLUMN split_right TEXT;")
        }
        migrator.registerMigration(names[11]) { db in
            try db.execute(sql: """
                CREATE TABLE feeds(id TEXT PRIMARY KEY, profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
                  url TEXT NOT NULL, title TEXT NOT NULL, folder TEXT NOT NULL DEFAULT '', UNIQUE(profile_id,url));
                CREATE TABLE feed_articles(id TEXT PRIMARY KEY, feed_id TEXT NOT NULL REFERENCES feeds(id) ON DELETE CASCADE,
                  title TEXT NOT NULL, url TEXT NOT NULL, published REAL NOT NULL, is_read INTEGER NOT NULL DEFAULT 0);
                CREATE INDEX feed_articles_date ON feed_articles(published DESC);
                """)
        }
        migrator.registerMigration(names[12]) { db in
            try db.execute(sql: """
                CREATE TABLE user_scripts(id TEXT PRIMARY KEY, profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE, name TEXT NOT NULL, payload BLOB NOT NULL);
                CREATE TABLE citations(id TEXT PRIMARY KEY, profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE, payload BLOB NOT NULL, created REAL NOT NULL);
                """)
        }
        migrator.registerMigration(names[13]) { db in
            try db.execute(sql: """
                CREATE TABLE ai_search_events(id TEXT PRIMARY KEY, profile_id TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE, query TEXT NOT NULL, created REAL NOT NULL, payload BLOB NOT NULL);
                CREATE INDEX ai_search_profile_date ON ai_search_events(profile_id,created DESC);
                CREATE TABLE ai_answer_tabs(tab_id TEXT PRIMARY KEY, event_id TEXT NOT NULL REFERENCES ai_search_events(id) ON DELETE CASCADE);
                """)
        }
        return migrator
    }
}
