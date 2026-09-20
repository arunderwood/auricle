/// The frontmatter schema version the app writes, and the newest version
/// `FrontmatterReader` accepts. `PersistStage` stamps it into every note and
/// into the persist row's `frontmatter_schema_version` metadata, and the
/// reader takes it as its upper bound, so a bump to what the app writes can
/// never leave the app's own reader rejecting its notes as too new.
public enum FrontmatterSchema {
    public static let current = 1
}
