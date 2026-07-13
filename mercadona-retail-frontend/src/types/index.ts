export interface Store {
  id: string;
  name: string;
  area: string;
  fulfilmentNote: string;
}

export interface Product {
  id: string;
  storeId: string;
  name: string;
  category: string;
  price: number;
  unit: string;
  icon: string;
}

export interface CartItem {
  productId: string;
  name: string;
  quantity: number;
  unitPrice: number;
  lineTotal: number;
}

export interface Cart {
  id: string;
  storeId: string;
  createdAt: string;
  items: CartItem[];
}

export interface Order {
  id: string;
  cartId: string;
  storeId: string;
  status: string;
  trackingCode: string;
  createdAt: string;
  items: CartItem[];
  total: number;
}

export interface Tracking {
  orderId: string;
  trackingCode: string;
  status: string;
  updatedAt: string;
  message: string;
}

export interface CartResponse {
  cart: Cart;
  correlationId: string;
  allocationBytes?: number;
  retainedBytes?: number;
  maxRetainedBytes?: number;
}

export interface OrderResponse {
  order: Order;
  correlationId: string;
}

export interface TrackingResponse {
  tracking: Tracking;
  correlationId: string;
}
