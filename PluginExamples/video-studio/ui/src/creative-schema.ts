import catalog from '../../schemas/creative-v1.json';

export type CreativeKind = keyof typeof catalog.$defs;
type Schema = {
  type: string; properties?: Record<string, Schema>; required?: string[];
  additionalProperties?: boolean; minProperties?: number;
  items?: Schema; maxItems?: number; minLength?: number; maxLength?: number;
  minimum?: number; exclusiveMinimum?: number; maximum?: number;
};

/** Validates the explicitly used JSON Schema vocabulary in creative-schemas.json. */
export function schemaErrors(schema: Schema, value: unknown, path = '$'): string[] {
  const errors: string[] = [];
  const fail = () => { errors.push(path); };
  if (schema.type === 'object') {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return [path];
    const record = value as Record<string, unknown>;
    if (Object.keys(record).length < (schema.minProperties ?? 0)) fail();
    for (const key of schema.required ?? []) if (!(key in record)) errors.push(`${path}.${key}`);
    for (const [key, entry] of Object.entries(record)) {
      const child = schema.properties?.[key];
      if (child) errors.push(...schemaErrors(child, entry, `${path}.${key}`));
      else if (schema.additionalProperties === false) errors.push(`${path}.${key}`);
    }
  } else if (schema.type === 'array') {
    if (!Array.isArray(value)) return [path];
    if (value.length > (schema.maxItems ?? Infinity)) fail();
    if (schema.items) value.forEach((item, index) => errors.push(...schemaErrors(schema.items!, item, `${path}[${index}]`)));
  } else if (schema.type === 'string') {
    if (typeof value !== 'string') return [path];
    const length = [...value].length;
    if (length < (schema.minLength ?? 0) || length > (schema.maxLength ?? Infinity)) fail();
  } else if (schema.type === 'integer' || schema.type === 'number') {
    if (typeof value !== 'number' || !Number.isFinite(value)) return [path];
    if (schema.type === 'integer' && !Number.isInteger(value)) fail();
    if (value < (schema.minimum ?? -Infinity) || value > (schema.maximum ?? Infinity)) fail();
    if (schema.exclusiveMinimum !== undefined && value <= schema.exclusiveMinimum) fail();
  } else throw new Error(`Unsupported schema type: ${schema.type}`);
  return errors;
}

export function validCreative(kind: CreativeKind, value: unknown): boolean {
  return schemaErrors(catalog.$defs[kind], value).length === 0;
}

export function creativeContract(kind: CreativeKind): string {
  return JSON.stringify({ schemaID: catalog.$id, ...catalog.$defs[kind] });
}
