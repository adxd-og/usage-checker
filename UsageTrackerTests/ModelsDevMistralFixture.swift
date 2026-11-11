import Foundation

/// models.dev's `mistral` family as `https://models.dev/api.json` answered on 2026-11-11 (spec
/// 2026-11-10 Mistral provider § Local usage (P2), Model and price): the rows vibe's sessions on
/// this Mac need and the shapes the price rule must handle, copied as fetched. Two ids share the
/// name "Devstral 2" and two share "GLM-5.2", each pair at one rate; a speech model has no
/// `cost`; "Mistral Medium 3.5" is `mistral-medium-2604`, vibe's default model.
enum ModelsDevMistralFixture {
    static let json = #"""
    {"mistral":{"id":"mistral","name":"Mistral","models":{
    "mistral-large-4":{"attachment":true,"canonical_model_id":"mistral/mistral-large-4","cost":{"cache_read":0.07,"input":0.7,"output":2.1},"description":"Mistral's 1T-parameter multimodal MoE for reasoning, coding, and agentic work","family":"mistral-large","id":"mistral-large-4","last_updated":"2026-10-06","limit":{"context":1048576,"output":262144},"modalities":{"input":["text","image","pdf"],"output":["text"]},"name":"Mistral Large 4","open_weights":false,"reasoning":true,"reasoning_options":[{"type":"effort","values":["low","medium","high"]}],"release_date":"2026-10-06","status":"beta","structured_output":true,"temperature":true,"tool_call":true},
    "mistral-large-4-0-8":{"attachment":true,"canonical_model_id":"mistral/mistral-large-4","cost":{"cache_read":0.07,"input":0.7,"output":2.1},"description":"Mistral's 1T-parameter multimodal MoE for reasoning, coding, and agentic work","family":"mistral-large","id":"mistral-large-4-0-8","last_updated":"2026-10-06","limit":{"context":1048576,"output":262144},"modalities":{"input":["text","image","pdf"],"output":["text"]},"name":"Mistral Large 4.0.8","open_weights":false,"reasoning":true,"reasoning_options":[{"type":"effort","values":["low","medium","high"]}],"release_date":"2026-10-06","status":"beta","structured_output":true,"temperature":true,"tool_call":true},
    "mistral-medium-2604":{"attachment":true,"cost":{"cache_read":0.15,"input":1.5,"output":7.5},"description":"Balanced Mistral model for enterprise assistants, multilingual work, and tools","family":"mistral-medium","id":"mistral-medium-2604","last_updated":"2026-04-29","limit":{"context":262144,"output":262144},"modalities":{"input":["text","image","pdf"],"output":["text"]},"name":"Mistral Medium 3.5","open_weights":true,"reasoning":true,"reasoning_options":[{"type":"effort","values":["none","high"]}],"release_date":"2026-04-29","structured_output":true,"temperature":true,"tool_call":true},
    "mistral-medium-latest":{"attachment":true,"canonical_model_id":"mistral/mistral-medium-latest","cost":{"cache_read":0.15,"input":1.5,"output":7.5},"description":"Balanced Mistral model for enterprise assistants, multilingual work, and tools","family":"mistral-medium","id":"mistral-medium-latest","last_updated":"2026-04-29","limit":{"context":262144,"output":262144},"modalities":{"input":["text","image","pdf"],"output":["text"]},"name":"Mistral Medium (latest)","open_weights":true,"reasoning":true,"reasoning_options":[{"type":"effort","values":["none","high"]}],"release_date":"2026-04-29","structured_output":true,"temperature":true,"tool_call":true},
    "zai-glm-5-3":{"attachment":false,"canonical_model_id":"zhipuai/glm-5.3","cost":{"cache_read":0.14,"input":1.4,"output":4.4},"description":"Flagship GLM model for long-horizon coding, agents, and complex project delivery","family":"glm","id":"zai-glm-5-3","last_updated":"2026-08-14","limit":{"context":1048576,"output":131072},"modalities":{"input":["text"],"output":["text"]},"name":"GLM-5.3","open_weights":true,"reasoning":true,"reasoning_options":[{"type":"effort","values":["low","high","max"]}],"release_date":"2026-08-14","structured_output":true,"temperature":true,"tool_call":true},
    "zai-glm-5-3-flash":{"attachment":true,"canonical_model_id":"zhipuai/glm-5.3-flash","cost":{"cache_read":0.03,"input":0.15,"output":0.5},"description":"Native multimodal GLM model for efficient coding and long-horizon agent tasks","family":"glm-flash","id":"zai-glm-5-3-flash","last_updated":"2026-08-26","limit":{"context":1048576,"output":131072},"modalities":{"input":["text","image","video","pdf"],"output":["text"]},"name":"GLM-5.3-Flash","open_weights":true,"reasoning":true,"reasoning_options":[{"type":"effort","values":["low","high","max"]}],"release_date":"2026-08-26","structured_output":true,"temperature":true,"tool_call":true},
    "devstral-2512":{"attachment":false,"cost":{"input":0.4,"output":2},"description":"Mistral's coding-agent model for repository work, terminal tasks, and software fixes","family":"devstral","id":"devstral-2512","knowledge":"2025-12","last_updated":"2025-12-09","limit":{"context":262144,"output":262144},"modalities":{"input":["text"],"output":["text"]},"name":"Devstral 2","open_weights":true,"reasoning":false,"release_date":"2025-12-09","status":"deprecated","temperature":true,"tool_call":true},
    "devstral-latest":{"attachment":false,"cost":{"input":0.4,"output":2},"description":"Legacy model retained for compatibility with older integrations","family":"devstral","id":"devstral-latest","knowledge":"2025-12","last_updated":"2025-12-09","limit":{"context":262144,"output":262144},"modalities":{"input":["text"],"output":["text"]},"name":"Devstral 2","open_weights":true,"reasoning":false,"release_date":"2025-12-09","status":"deprecated","temperature":true,"tool_call":true},
    "glm-5-2":{"attachment":false,"canonical_model_id":"zhipuai/glm-5.2","cost":{"cache_read":0.14,"input":1.4,"output":4.4},"description":"Open flagship GLM for long-horizon coding agents and million-token context work","family":"glm","id":"glm-5-2","last_updated":"2026-06-13","limit":{"context":1048576,"output":131072},"modalities":{"input":["text"],"output":["text"]},"name":"GLM-5.2","open_weights":true,"reasoning":true,"reasoning_options":[{"type":"effort","values":["none","high","max"]}],"release_date":"2026-06-13","status":"deprecated","structured_output":true,"temperature":true,"tool_call":true},
    "zai-glm-5-2":{"attachment":false,"canonical_model_id":"zhipuai/glm-5.2","cost":{"cache_read":0.14,"input":1.4,"output":4.4},"description":"Open flagship GLM for long-horizon coding agents and million-token context work","family":"glm","id":"zai-glm-5-2","last_updated":"2026-06-13","limit":{"context":1048576,"output":131072},"modalities":{"input":["text"],"output":["text"]},"name":"GLM-5.2","open_weights":true,"reasoning":true,"reasoning_options":[{"type":"effort","values":["none","high","max"]}],"release_date":"2026-06-13","status":"deprecated","structured_output":true,"temperature":true,"tool_call":true},
    "voxtral-mini-latest":{"attachment":true,"description":"Speech transcription model for accurate audio-to-text and captioning workflows","family":"voxtral","id":"voxtral-mini-latest","last_updated":"2026-02-04","limit":{"context":0,"output":0},"modalities":{"input":["audio"],"output":["text"]},"name":"Voxtral Mini (latest)","open_weights":false,"reasoning":false,"release_date":"2026-02-04","temperature":false,"tool_call":false,"type":"transcription"}
    }}}
    """#

    /// The answer as `ModelsDevPricing` reads it.
    static var root: [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
    }

    /// An edited copy, not as fetched: `devstral-latest`'s input rate moved from 0.4 to 0.5, so
    /// the name "Devstral 2" stands for two models at two rates.
    static var rootWithDifferingDuplicates: [String: Any] {
        var edited = root
        var mistral = edited["mistral"] as? [String: Any] ?? [:]
        var models = mistral["models"] as? [String: Any] ?? [:]
        var devstral = models["devstral-latest"] as? [String: Any] ?? [:]
        devstral["cost"] = ["input": 0.5, "output": 2]
        models["devstral-latest"] = devstral
        mistral["models"] = models
        edited["mistral"] = mistral
        return edited
    }
}
