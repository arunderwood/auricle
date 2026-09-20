/// The name of the cache artifact that holds the user's speaker attribution.
/// It lives in `Core` because the stage that writes it and the summarize
/// stage that reads it must not depend on each other.
public enum AttributionArtifact {
    public static let fileName = "attribution.json"
}
