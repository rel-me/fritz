# Tolerate brief local chat startup memory warnings

## User request

> you start the model and then submit a short request..
> Can you watch memory pressure and tell me what context size Automatic picks and how big the KV cache is?
>
> it's not getting through... do we need to remove the memory pressure check?

The first test stopped on a brief startup warning. The follow-up accepts requiring the warning to persist while keeping immediate stops for critical pressure and swap growth.

> ok try that

## Delegated prompt

> Monitor the startup memory warning PR and fix failures caused by the change. Verify the exact head after each fix. Keep local verification light and leave any real Inkling run to the parent.
