# APIM / PTU Monitoring Workbook

One dashboard for APIM and PTU health. Uses existing Azure Monitor metrics. Nothing to turn on.

## Deploy (portal only)

1. Azure portal > **Monitor** > **Workbooks** > **+ New**.
2. Click **Advanced Editor** (`</>`).
3. Replace the contents with `apim-validation.workbook.json`.
4. Click **Apply**, then **Done Editing**.
5. Select your **APIM instance**. Optionally select your **Foundry / Azure OpenAI resource** to add PTU charts.
6. (Optional) **Save**.

## How to read it

| You see | Meaning |
|---|---|
| **Utilization V2** near 100% | PTU is exhausted |
| **Time to Response** rising, Utilization V2 under 100% | PTU is slowing down (early warning) |
| **Tokens Per Second** dropping | Generation is slowing |
| **Gateway CPU %** or **Gateway memory %** high | Scale APIM |
| 4xx/5xx in **Requests (by gateway code)**, clean **Requests (by backend code)** | APIM rejected the call (bad key, rate limit, quota). Not a PTU problem |
| 429/5xx in **Requests (by backend code)** | The PTU returned the error |
| **Duration** far above **Backend Duration** | Delay is in APIM policies |

## Need results per APIM subscription?

See [subscription-usage/README.md](subscription-usage/README.md).
