use serde_json::Value;

// Background candidate generation can arrive through the same completion hook
// as a user-facing answer. Match only its bare JSON envelope, not JSON in
// general, fenced examples, or prose that mentions these field names.
pub fn is_candidate_generation(body: &str) -> bool {
    let Ok(Value::Object(fields)) = serde_json::from_str::<Value>(body.trim()) else {
        return false;
    };
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
    fn suppresses_only_candidate_envelopes() {
        for body in [
            r#"{"exclude":[]}"#,
            r#"{"exclude":["previous-task"]}"#,
            r#"{"suggestions":[]}"#,
            r#"{"suggestions":[{"title":"","prompt":"next task"}]}"#,
            r#"{"exclude":[],"suggestions":[{"title":"候補"}]}"#,
        ] {
            assert!(is_candidate_generation(body), "{body}");
        }
    }

    #[test]
    fn preserves_answers_json_examples_and_unrecognized_shapes() {
        for body in [
            "実装しました。",
            "許可をお願いします",
            r#"{"status":"ok","count":2}"#,
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
            assert!(!is_candidate_generation(body), "{body}");
        }
    }
}
