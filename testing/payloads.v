module testing

import json2

// The payloads come from user 7 ("ana") in channel 300 of guild 30, the way Discord sends them.

const member = '"guild_id":"30","channel_id":"300","member":{"user":{"id":"7","username":"ana"},"roles":[],"permissions":"0"},"app_permissions":"0","locale":"en-US"'

// command_interaction is a slash command; `options` is the JSON array of its options, such as
// '[{"name":"text","type":3,"value":"hi"}]'.
pub fn command_interaction(name string, options string) string {
	return '{"id":"100","application_id":"1","type":2,"token":"token",${member},"data":{"id":"5","name":"${name}","type":1,"options":${options}}}'
}

// component_interaction is a click, or a pick of `values`, on a component of message 200.
pub fn component_interaction(custom_id string, values []string) string {
	return '{"id":"101","application_id":"1","type":3,"token":"token",${member},"message":{"id":"200","channel_id":"300","author":{"id":"1","username":"bot"},"content":"","timestamp":""},"data":{"custom_id":"${custom_id}","component_type":2,"values":${json2.encode(values)}}}'
}

// modal_submit is a modal sent with `values`, input custom_id to text.
pub fn modal_submit(custom_id string, values map[string]string) string {
	mut inputs := []string{}
	for id, value in values {
		inputs << '{"type":18,"component":{"type":4,"custom_id":"${id}","value":${json2.encode(value)}}}'
	}
	return '{"id":"102","application_id":"1","type":5,"token":"token",${member},"data":{"custom_id":"${custom_id}","components":[${inputs.join(',')}]}}'
}

// message_create is a message from ana, for prefix commands and listeners.
pub fn message_create(content string) string {
	return '{"id":"400","channel_id":"300","guild_id":"30","author":{"id":"7","username":"ana"},"member":{"roles":[]},"content":${json2.encode(content)},"timestamp":"2026-01-01T00:00:00+00:00","mentions":[]}'
}
