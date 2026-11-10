"""GLM-OCR taken apart into the two graphs the app would run, written without the cache objects and Python loops of transformers
so that they export to ONNX.
VisionPart(pixel_values [N, 1176], pos_ids [N, 2]) -> image features [N / 4, 1536]
  pixel_values: the patches as the HF processor gives them (per patch: channel, 2 frames, 14, 14); pos_ids: row and column of each patch
  in the order of the patches (merge blocks of 2 x 2 patches are contiguous; see vision_pos_ids).
TextPart(inputs_embeds [1, T, 1536], position_ids [3, 1, T], attention_mask [1, P], past_key_values.i.key/value [1, 8, P, 128])
  -> logits of the LAST position [1, 1, vocab], present.i.key/value [1, 8, P + T, 128]
  The mask covers the cache only: a 0 for its first, dummy position (so that the cache is never empty), 1 for the rest."""
import numpy as np, torch, torch.nn as nn, torch.nn.functional as F
from transformers.models.glm_ocr import modeling_glm_ocr as M

class VisionPart(nn.Module):
    def __init__(self, vis, max_grid=512):
        super().__init__()
        self.vis = vis
        self.register_buffer('table', vis.rotary_pos_emb(max_grid), persistent=False)   # [max_grid, 16]
        self.w_patch = nn.Parameter(vis.patch_embed.proj.weight.detach().reshape(vis.patch_embed.embed_dim, -1), requires_grad=False)
        self.b_patch = nn.Parameter(vis.patch_embed.proj.bias.detach(), requires_grad=False)
        self.w_down = nn.Parameter(vis.downsample.weight.detach().reshape(vis.downsample.out_channels, -1), requires_grad=False)
        self.b_down = nn.Parameter(vis.downsample.bias.detach(), requires_grad=False)

    def forward(self, pixel_values, pos_ids):
        v = self.vis
        h = F.linear(pixel_values, self.w_patch, self.b_patch)
        n = h.shape[0]
        rot = self.table[pos_ids].flatten(1)
        emb = torch.cat((rot, rot), dim=-1)
        cos, sin = emb.cos(), emb.sin()
        for blk in v.blocks:
            a = blk.attn
            qkv = a.qkv(blk.norm1(h)).reshape(n, 3, a.num_heads, -1).permute(1, 0, 2, 3)
            q, k, val = qkv[0], qkv[1], qkv[2]
            q, k = a.q_norm(q), a.k_norm(k)
            q, k = M.apply_rotary_pos_emb_vision(q, k, cos, sin)
            q, k, val = [t.transpose(0, 1).unsqueeze(0) for t in (q, k, val)]
            o = F.scaled_dot_product_attention(q, k, val)            # [1, heads, n, head_dim]
            h = h + a.proj(o.squeeze(0).transpose(0, 1).reshape(n, -1))
            h = h + blk.mlp(blk.norm2(h))
        h = v.post_layernorm(h)
        c = h.shape[-1]
        h = h.view(-1, 2, 2, c).permute(0, 3, 1, 2).reshape(-1, 4 * c)
        h = F.linear(h, self.w_down, self.b_down)
        return v.merger(h)

class TextPart(nn.Module):
    def __init__(self, model):
        super().__init__()
        self.lm = model.model.language_model
        self.head = model.lm_head
        cfg = self.lm.config
        self.layers_n, self.groups = cfg.num_hidden_layers, cfg.num_attention_heads // cfg.num_key_value_heads

    def forward(self, inputs_embeds, position_ids, attention_mask, past):
        lm = self.lm
        t = inputs_embeds.shape[1]
        attention_mask = torch.cat([attention_mask, torch.ones(1, t, dtype=attention_mask.dtype)], dim=1)   # (the mask of the cache, then the new tokens)
        s = attention_mask.shape[1]
        cos, sin = lm.rotary_emb(inputs_embeds, position_ids)
        allowed = (torch.arange(s)[None, :] <= (torch.arange(t) + (s - t))[:, None]) & (attention_mask[:, None, :] != 0)   # [1, t, s]
        mask = allowed[:, None, :, :]
        h = inputs_embeds
        present = []
        for i, layer in enumerate(lm.layers):
            at = layer.self_attn
            x = layer.input_layernorm(h)
            q = at.q_proj(x).view(1, t, -1, at.head_dim).transpose(1, 2)
            k = at.k_proj(x).view(1, t, -1, at.head_dim).transpose(1, 2)
            v = at.v_proj(x).view(1, t, -1, at.head_dim).transpose(1, 2)
            q, k = M.apply_rotary_pos_emb(q, k, cos, sin)
            k = torch.cat([past[2 * i], k], dim=2)
            v = torch.cat([past[2 * i + 1], v], dim=2)
            present += [k, v]
            o = F.scaled_dot_product_attention(q, M.repeat_kv(k, self.groups), M.repeat_kv(v, self.groups), attn_mask=mask)
            o = at.o_proj(o.transpose(1, 2).reshape(1, t, -1))
            h = h + layer.post_self_attn_layernorm(o)
            h = h + layer.post_mlp_layernorm(layer.mlp(layer.post_attention_layernorm(h)))
        h = lm.norm(h[:, -1:, :])
        return (self.head(h), *present)

def vision_pos_ids(grid_h, grid_w, merge=2):
    """Row and column of every patch of a grid_h x grid_w picture, in the order the processor lays the patches out (blocks of 2 x 2)."""
    r = np.arange(grid_h)[:, None].repeat(grid_w, 1).reshape(grid_h // merge, merge, grid_w // merge, merge).transpose(0, 2, 1, 3).reshape(-1)
    c = np.arange(grid_w)[None, :].repeat(grid_h, 0).reshape(grid_h // merge, merge, grid_w // merge, merge).transpose(0, 2, 1, 3).reshape(-1)
    return np.stack([r, c], 1).astype(np.int64)

def text_position_ids(types, grid_h, grid_w, merge=2):
    """The [3, T] positions of a prompt: `types` is 0 for a text token and 1 for a picture token (one run of them); text goes 0, 1, 2 ...
    on all three rows, the picture's tokens share the position the picture starts at in time and take row and column from the grid, and
    the text after the picture carries on from the start plus the longer side of the (merged) grid."""
    pos, cur, i = [], 0, 0
    types = list(types)
    while i < len(types):
        j = i
        while j < len(types) and types[j] == types[i]: j += 1
        if types[i] == 0:
            pos.append(np.arange(j - i)[None, :].repeat(3, 0) + cur); cur += j - i
        else:
            gh, gw = grid_h // merge, grid_w // merge
            rr = np.arange(gh)[:, None].repeat(gw, 1).reshape(-1); cc = np.arange(gw)[None, :].repeat(gh, 0).reshape(-1)
            pos.append(np.stack([np.full(gh * gw, cur), cur + rr, cur + cc])); cur += max(gh, gw)
        i = j
    return np.concatenate(pos, 1).astype(np.int64)
