const Anthropic = require('@anthropic-ai/sdk');
const { betaZodOutputFormat } = require('@anthropic-ai/sdk/helpers/beta/zod');
const config = require('./config');

let client;
function getClient() {
  if (!config.anthropicApiKey) return null;
  if (!client) client = new Anthropic({ apiKey: config.anthropicApiKey });
  return client;
}

const isEnabled = () => Boolean(config.anthropicApiKey);

/**
 * เรียก Claude แล้วได้ผลลัพธ์เป็น JSON ตาม zod schema
 * - fallbacks: "default" → ถ้าโมเดลปฏิเสธ (refusal) API จะลองโมเดลสำรองให้อัตโนมัติ
 * - throw เมื่อถูกปฏิเสธ / ถูกตัด / parse ไม่ได้ เพื่อให้ผู้เรียกเลือกทางปลอดภัย (HOLD)
 */
async function structured({ system, prompt, schema, effort = 'medium', maxTokens = 16000 }) {
  const c = getClient();
  if (!c) throw new Error('ANTHROPIC_API_KEY ไม่ได้ตั้งค่า');

  const response = await c.beta.messages.parse({
    model: config.model,
    max_tokens: maxTokens,
    betas: ['server-side-fallback-2026-07-01'],
    fallbacks: 'default',
    system,
    messages: [{ role: 'user', content: prompt }],
    output_config: { effort, format: betaZodOutputFormat(schema) },
  });

  if (response.stop_reason === 'refusal') throw new Error('Claude ปฏิเสธคำขอ (refusal)');
  if (response.stop_reason === 'max_tokens') throw new Error('คำตอบถูกตัดเพราะ max_tokens');
  if (!response.parsed_output) throw new Error('parse ผลลัพธ์จาก Claude ไม่ได้');

  return {
    data: response.parsed_output,
    usage: { input: response.usage.input_tokens, output: response.usage.output_tokens, model: response.model },
  };
}

module.exports = { structured, isEnabled };
