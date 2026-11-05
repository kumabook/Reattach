use serde_json::Value;

// Background candidate and title generation can arrive through the same
// completion hook as a user-facing answer. Match only their bare JSON envelopes,
// not JSON in general, fenced examples, or prose mentioning these field names.
pub fn is_background_generation(body: &str) -> bool {
    let Ok(Value::Object(fields)) = serde_json::from_str::<Value>(body.trim()) else {
        return false;
    };
    if fields.len() == 1 && fields.get("title").is_some_and(Value::is_string) {
        return true;
    }
    if fields.is_empty()
        || fields
            .keys()
            .any(|key| key != "exclude" && key != "suggestions")
    {
        return false;
    }
    fields.iter().all(|(key, value)| {
        let Some(items) = value.as_array() else {
            return false;
        };
        match key.as_str() {
            "exclude" => items.iter().all(Value::is_string),
            "suggestions" => items.iter().all(|item| {
                item.as_object()
                    .and_then(|object| object.get("title"))
                    .is_some_and(Value::is_string)
            }),
            _ => false,
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn suppresses_only_background_generation_envelopes() {
        for body in [
            r#"{ "title": "xxxx" }"#,
            " \n{\n  \"title\": \"タイトル\"\n}\n ",
            r#"{"title":""}"#,
            r#"{"exclude":[]}"#,
            r#"{"exclude":["previous-task"]}"#,
            r#"{"suggestions":[]}"#,
            r#"{"suggestions":[{"title":"","prompt":"next task"}]}"#,
            r#"{"exclude":[],"suggestions":[{"title":"候補"}]}"#,
        ] {
            assert!(is_background_generation(body), "{body}");
        }
    }

    #[test]
    fn preserves_answers_json_examples_and_unrecognized_shapes() {
        for body in [
            "実装しました。",
            "許可をお願いします",
            r#"{"status":"ok","count":2}"#,
            r#"{"title":"answer","body":"user content"}"#,
            r#"{"title":null}"#,
            r#"{"title":123}"#,
            r#"{"title":["answer"]}"#,
            "```json\n{\"title\":\"example\"}\n```",
            "設定例: {\"title\":\"example\"}",
            r#"{"exclude":[],"result":"user answer"}"#,
            r#"{"suggestions":"answer"}"#,
            r#"{"suggestions":["one","two"]}"#,
            r#"{"suggestions":[{"title":null}]}"#,
            r#"{"exclude":[1]}"#,
            "```json\n{\"exclude\":[]}\n```",
            "設定例: {\"exclude\":[]}",
            "{\"suggestions\":[",
            "{}",
            "[]",
        ] {
            assert!(!is_background_generation(body), "{body}");
        }
    }
}
