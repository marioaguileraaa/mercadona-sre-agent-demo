import {
  ApiErrorDetails,
  CartResponse,
  OrderResponse,
  Product,
  Store,
  TrackingResponse,
} from '../types';

export class ApiError extends Error {
  constructor(
    message: string,
    public readonly status: number,
    public readonly details?: ApiErrorDetails,
  ) {
    super(message);
  }
}

export async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, {
    ...init,
    headers: {
      'Content-Type': 'application/json',
      ...init?.headers,
    },
  });
  const body = response.status === 204 ? undefined : await response.json() as ApiErrorDetails;
  if (!response.ok) {
    throw new ApiError(body?.message || `API request failed (${response.status})`, response.status, body);
  }
  return body as T;
}

export const retailApi = {
  getStores: () => request<Store[]>('/api/stores'),
  getProducts: (storeId: string) =>
    request<Product[]>(`/api/products/store/${encodeURIComponent(storeId)}`),
  createCart: (storeId: string) =>
    request<CartResponse>('/api/carts', {
      method: 'POST',
      body: JSON.stringify({ storeId }),
    }),
  getCart: (cartId: string) =>
    request<CartResponse>(`/api/carts/${encodeURIComponent(cartId)}`),
  addCartItem: (cartId: string, productId: string, quantity = 1) =>
    request<CartResponse>(`/api/carts/${encodeURIComponent(cartId)}/items`, {
      method: 'POST',
      body: JSON.stringify({ productId, quantity }),
    }),
  createOrder: (cartId: string) =>
    request<OrderResponse>('/api/orders', {
      method: 'POST',
      body: JSON.stringify({ cartId }),
    }),
  getTracking: (orderId: string) =>
    request<TrackingResponse>(`/api/orders/${encodeURIComponent(orderId)}/tracking`),
};
