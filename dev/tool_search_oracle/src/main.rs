//! Development-only oracle. No Rust is used by the Runtime or ordinary tests.
use bm25::{DefaultTokenizer, Language, Tokenizer, EmbedderBuilder, Scorer};
use serde_json::{json, Value};
use std::io::{self, BufRead};
// Field traversal follows pinned/search-text.rs; Backplane Contract adapter only.
fn push(parts: &mut Vec<String>, value: &Value) {
    if let Some(s) = value.as_str() { let s = s.trim(); if !s.is_empty() {parts.push(s.to_owned());} }
}
fn schema_text(value: &Value, parts: &mut Vec<String>) {
    push(parts, &value["description"]);
    if let Some(properties) = value["properties"].as_object() {
        // serde_json default map is sorted (same BTreeMap order as pinned JsonSchema).
        for (name, child) in properties { push(parts, &json!(name)); schema_text(child, parts); }
    }
    if !value["items"].is_null() { schema_text(&value["items"], parts); }
    if let Some(variants) = value["anyOf"].as_array() { for child in variants {schema_text(child, parts);} }
}
fn metadata_text(tool: &Value) -> String {
    let mut parts = Vec::new();
    if let Some(namespace) = tool["namespace"].as_str() {
        push(&mut parts, &json!(namespace));
        let description = tool["metadata"]["namespace_description"].as_str().unwrap_or("");
        let description = if description.trim().is_empty() {
            if namespace == "functions" {String::new()} else {format!("Tools in the {namespace} namespace.")}
        } else {description.to_owned()};
        push(&mut parts, &json!(description));
    }
    push(&mut parts, &tool["name"]);
    if tool["input_kind"] != "custom" {push(&mut parts, &json!(tool["name"].as_str().unwrap().replace('_', " ")));}
    push(&mut parts, &tool["description"]);
    if tool["input_kind"] == "custom" {push(&mut parts, &tool["format"]["syntax"]);} else {schema_text(&tool["schema"], &mut parts);}
    parts.join(" ")
}
fn main() {
    for line in io::stdin().lock().lines() {
        let input: Value = serde_json::from_str(&line.unwrap()).unwrap();
        let tokenizer = DefaultTokenizer::new(Language::English);
        let texts: Vec<String> = match input["contracts"].as_array() {
            Some(contracts) => contracts.iter().map(metadata_text).collect(),
            None => input["texts"].as_array().unwrap().iter().map(|s| s.as_str().unwrap().to_owned()).collect()
        };
        let tokenized: Vec<_> = texts.iter().map(|s| {
            let tokens = tokenizer.tokenize(s);
            let hashes: Vec<_> = tokens.iter().map(|t| fxhash::hash32(t.as_str())).collect();
            json!({"text": s, "normalized": deunicode::deunicode(s), "tokens": tokens, "hashes": hashes})
        }).collect();
        let docs: Vec<&str> = texts.iter().map(|s| s.as_str()).collect();
        let embedder = EmbedderBuilder::<u32>::with_tokenizer_and_fit_to_corpus(DefaultTokenizer::new(Language::English), &docs).build();
        let mut scorer = Scorer::<usize>::new();
        for (id, text) in texts.iter().enumerate() { scorer.upsert(&id, embedder.embed(text)); }
        let queries: Vec<_> = input["queries"].as_array().unwrap().iter().map(|q| {
            let q = q.as_str().unwrap();
            let embedding = embedder.embed(q);
            let scores: Vec<_> = (0..texts.len()).map(|id| json!({"id": id, "score": scorer.score(&id, &embedding).unwrap()})).collect();
            json!({"query": q, "scores": scores})
        }).collect();
        println!("{}", json!({"documents": tokenized, "queries": queries}));
    }
}
