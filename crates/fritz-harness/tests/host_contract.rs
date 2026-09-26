use anyhow::Result;
use fritz_harness::{Host, Limits, Model, ToolCall, ToolDefinition, ToolResult, Turn, run};
use serde_json::json;
use std::{cell::RefCell, collections::VecDeque, future::pending, time::Duration};

fn call(id: &str, name: &str) -> ToolCall {
    ToolCall {
        id: id.into(),
        name: name.into(),
        arguments: "{}".into(),
    }
}

fn limits(turns: usize, tools: usize) -> Limits {
    Limits {
        model_turns: turns,
        tool_calls: tools,
        deadline: Duration::from_secs(1),
    }
}

struct FixtureModel {
    turns: VecDeque<Vec<ToolCall>>,
    advertised: Vec<Vec<String>>,
    results: Vec<(ToolCall, ToolResult)>,
}

impl FixtureModel {
    fn new(turns: Vec<Vec<ToolCall>>) -> Self {
        Self {
            turns: turns.into(),
            advertised: Vec::new(),
            results: Vec::new(),
        }
    }
}

impl Model for FixtureModel {
    async fn turn(&mut self, tools: &[ToolDefinition]) -> Result<Turn> {
        self.advertised
            .push(tools.iter().map(|tool| tool.name.clone()).collect());
        Ok(Turn {
            calls: self.turns.pop_front().expect("unexpected model call"),
            has_text: true,
        })
    }

    fn results(&mut self, results: Vec<(ToolCall, ToolResult)>) -> Result<()> {
        self.results.extend(results);
        Ok(())
    }
}

#[derive(Default)]
struct FixtureHost {
    executed: RefCell<Vec<String>>,
}

impl Host for FixtureHost {
    fn tools(&self) -> Result<Vec<ToolDefinition>> {
        let name = if self.executed.borrow().is_empty() {
            "prepare"
        } else {
            "finish"
        };
        Ok(vec![ToolDefinition {
            name: name.into(),
            description: "Host-owned action".into(),
            parameters: json!({"type":"object","properties":{}}),
        }])
    }

    async fn execute(&self, call: &ToolCall) -> Result<ToolResult> {
        self.executed.borrow_mut().push(call.name.clone());
        Ok(ToolResult::json(json!({"receipt":call.id}), false))
    }
}

#[tokio::test]
async fn host_changes_tools_between_turns_and_receipts_keep_call_identity() {
    let host = FixtureHost::default();
    let mut model = FixtureModel::new(vec![
        vec![call("first", "prepare")],
        vec![call("second", "finish")],
        vec![],
    ]);
    run(&mut model, &host, limits(3, 2)).await.unwrap();
    assert_eq!(
        model.advertised,
        vec![vec!["prepare"], vec!["finish"], vec!["finish"]]
    );
    assert_eq!(*host.executed.borrow(), vec!["prepare", "finish"]);
    assert_eq!(model.results[0].0.id, "first");
    assert_eq!(model.results[1].1.value, json!({"receipt":"second"}));
}

#[tokio::test]
async fn invalid_batches_and_exhausted_limits_never_partially_execute() {
    for (calls, budget, expected) in [
        (
            vec![call("a", "prepare"), call("b", "hidden")],
            limits(2, 3),
            "unavailable tool",
        ),
        (
            vec![call("a", "prepare"), call("b", "prepare")],
            limits(2, 1),
            "1-tool limit",
        ),
        (vec![call("a", "prepare")], limits(1, 1), "model-turn limit"),
        (
            vec![call("a", "prepare"), call("a", "prepare")],
            limits(2, 3),
            "unique within a turn",
        ),
    ] {
        let host = FixtureHost::default();
        let mut model = FixtureModel::new(vec![calls]);
        let error = run(&mut model, &host, budget).await.unwrap_err();
        assert!(error.to_string().contains(expected), "{error}");
        assert!(host.executed.borrow().is_empty());
        assert!(model.results.is_empty());
    }
    let host = FixtureHost::default();
    let mut model = FixtureModel::new(vec![vec![call("a", "prepare")], vec![call("b", "prepare")]]);
    assert!(
        run(&mut model, &host, limits(3, 3))
            .await
            .unwrap_err()
            .to_string()
            .contains("unavailable tool")
    );
    assert_eq!(*host.executed.borrow(), vec!["prepare"]);
}

struct PendingHost {
    state: RefCell<&'static str>,
}

struct RecoveringHost(FixtureHost);
impl Host for RecoveringHost {
    fn tools(&self) -> Result<Vec<ToolDefinition>> {
        self.0.tools()
    }
    async fn execute(&self, call: &ToolCall) -> Result<ToolResult> {
        self.0.execute(call).await
    }
    fn unavailable_tool(&self, _: &ToolCall) -> Result<ToolResult> {
        Ok(ToolResult::json(
            json!({"error":"Use an advertised tool"}),
            true,
        ))
    }
}

#[tokio::test]
async fn recovery_skips_the_entire_invalid_batch_and_accepts_a_corrected_call() {
    let host = RecoveringHost(FixtureHost::default());
    let mut model = FixtureModel::new(vec![
        vec![call("a", "prepare"), call("b", "hidden")],
        vec![call("c", "prepare")],
        vec![],
    ]);
    run(&mut model, &host, limits(3, 3)).await.unwrap();
    assert_eq!(*host.0.executed.borrow(), vec!["prepare"]);
    assert!(model.results[0].1.failed && model.results[1].1.failed);
    assert_eq!(model.results[2].1.value, json!({"receipt":"c"}));

    let host = RecoveringHost(FixtureHost::default());
    let mut model = FixtureModel::new(vec![vec![call("a", "hidden")], vec![call("b", "prepare")]]);
    assert!(
        run(&mut model, &host, limits(3, 1))
            .await
            .unwrap_err()
            .to_string()
            .contains("1-tool limit")
    );
    assert!(host.0.executed.borrow().is_empty());
}
struct Active<'a>(&'a RefCell<&'static str>);
impl Drop for Active<'_> {
    fn drop(&mut self) {
        *self.0.borrow_mut() = "dropped";
    }
}
impl Host for PendingHost {
    fn tools(&self) -> Result<Vec<ToolDefinition>> {
        FixtureHost::default().tools()
    }
    async fn execute(&self, _: &ToolCall) -> Result<ToolResult> {
        *self.state.borrow_mut() = "running";
        let _active = Active(&self.state);
        pending().await
    }
}

#[tokio::test(start_paused = true)]
async fn deadline_drops_in_flight_tool_without_committing_a_result() {
    let host = PendingHost {
        state: RefCell::new("idle"),
    };
    let mut model = FixtureModel::new(vec![vec![call("a", "prepare")]]);
    assert!(
        run(&mut model, &host, limits(2, 1))
            .await
            .unwrap_err()
            .to_string()
            .contains("deadline")
    );
    assert_eq!(*host.state.borrow(), "dropped");
    assert!(model.results.is_empty());
}
