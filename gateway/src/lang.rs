//! The language of the words the Gateway writes for a phone itself: failure
//! messages and the few labels it puts in a conversation. The phone names
//! the language it shows (`lang` on every `/v0/…` URL); what herdr-core,
//! git or the Agent wrote passes through as it is.

/// Chinese or English; any other language reads English, like the app.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Lang {
    /// Also for phones too old to send `lang`: their interface is Chinese.
    #[default]
    Chinese,
    English,
}

impl Lang {
    /// From a BCP 47 tag such as `en-GB`, `fr` or `zh-Hans-CN`.
    pub fn from_tag(tag: Option<&str>) -> Self {
        match tag.map(str::trim) {
            None | Some("") => Self::Chinese,
            Some(tag) if tag.get(..2).is_some_and(|primary| primary.eq_ignore_ascii_case("zh")) => Self::Chinese,
            Some(_) => Self::English,
        }
    }

    /// `chinese` or `english`, whichever this phone reads.
    pub fn pick<T>(self, chinese: T, english: T) -> T {
        match self {
            Self::Chinese => chinese,
            Self::English => english,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_phones_tag() {
        assert_eq!(Lang::from_tag(None), Lang::Chinese);
        assert_eq!(Lang::from_tag(Some("")), Lang::Chinese);
        assert_eq!(Lang::from_tag(Some("zh-Hans")), Lang::Chinese);
        assert_eq!(Lang::from_tag(Some("ZH-Hant-TW")), Lang::Chinese);
        assert_eq!(Lang::from_tag(Some("zh")), Lang::Chinese);
        assert_eq!(Lang::from_tag(Some("en")), Lang::English);
        assert_eq!(Lang::from_tag(Some("en-GB")), Lang::English);
        assert_eq!(Lang::from_tag(Some("fr-FR")), Lang::English);
        assert_eq!(Lang::from_tag(Some("z")), Lang::English);
        assert_eq!(Lang::English.pick("中", "en"), "en");
    }
}
