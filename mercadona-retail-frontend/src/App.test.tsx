import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import App from './App';
import { retailApi } from './services/api';

jest.mock('./services/api', () => ({
  retailApi: {
    getStores: jest.fn(),
    getProducts: jest.fn(),
    createCart: jest.fn(),
    addCartItem: jest.fn(),
    createOrder: jest.fn(),
    getTracking: jest.fn(),
  },
}));

const store = {
  id: 'store-river',
  name: 'Mercado Río Verde',
  area: 'Distrito Demo de Valencia',
  fulfilmentNote: 'Recogida sintética en el día',
};

const product = {
  id: 'product-apples',
  storeId: store.id,
  name: 'Manzanas crujientes',
  category: 'Fruta y verdura',
  price: 2.35,
  unit: '1 kg',
  icon: 'apple',
};

const emptyCart = {
  id: 'CART-1',
  storeId: store.id,
  createdAt: '2026-07-13T12:00:00Z',
  items: [],
};

const cartWithItem = {
  ...emptyCart,
  items: [{
    productId: product.id,
    name: product.name,
    quantity: 1,
    unitPrice: product.price,
    lineTotal: product.price,
  }],
};

beforeEach(() => {
  jest.clearAllMocks();
  (retailApi.getStores as jest.Mock).mockResolvedValue([store]);
  (retailApi.getProducts as jest.Mock).mockResolvedValue([product]);
  (retailApi.createCart as jest.Mock).mockResolvedValue({
    cart: emptyCart,
    correlationId: 'CORR-CART',
  });
});

test('renders the original Mercado Verde identity and persistent synthetic disclaimer', async () => {
  render(<App />);

  expect(await screen.findByRole('button', { name: 'Mercado Verde, ir al inicio' })).toBeInTheDocument();
  expect(screen.getByText(/Fictional technical SRE demo/)).toBeInTheDocument();
  expect(screen.getAllByText(/Demo técnica SRE ficticia/)).toHaveLength(2);
  expect(screen.getAllByText(/No es un sistema oficial de Mercadona/)).toHaveLength(2);
  expect(screen.getByRole('heading', { name: /Lo cotidiano/ })).toBeInTheDocument();
});

test('selects a store, filters its catalog and handles an empty result', async () => {
  render(<App />);

  fireEvent.click(await screen.findByRole('button', { name: 'Comprar aquí' }));

  expect(await screen.findByText(product.name)).toBeInTheDocument();
  expect(retailApi.getProducts).toHaveBeenCalledWith(store.id);
  expect(retailApi.createCart).toHaveBeenCalledWith(store.id);

  fireEvent.change(screen.getByRole('textbox', { name: 'Buscar productos sintéticos' }), {
    target: { value: 'sin coincidencias' },
  });

  expect(screen.getByRole('heading', { name: 'No encontramos coincidencias' })).toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: 'Ver todos los productos' }));
  expect(screen.getByText(product.name)).toBeInTheDocument();
});

test('adds through the cart API and completes checkout with tracking', async () => {
  (retailApi.addCartItem as jest.Mock).mockResolvedValue({
    cart: cartWithItem,
    correlationId: 'CORR-ADD',
  });
  (retailApi.createOrder as jest.Mock).mockResolvedValue({
    order: {
      id: 'ORDER-1',
      cartId: emptyCart.id,
      storeId: store.id,
      status: 'Confirmado',
      trackingCode: 'TRACK-1',
      createdAt: '2026-07-13T12:05:00Z',
      items: cartWithItem.items,
      total: product.price,
    },
    correlationId: 'CORR-ORDER',
  });
  (retailApi.getTracking as jest.Mock).mockResolvedValue({
    tracking: {
      orderId: 'ORDER-1',
      trackingCode: 'TRACK-1',
      status: 'Preparing',
      updatedAt: '2026-07-13T12:06:00Z',
      message: 'Synthetic order is being prepared for the demo.',
    },
    correlationId: 'CORR-TRACK',
  });

  render(<App />);
  fireEvent.click(await screen.findByRole('button', { name: 'Comprar aquí' }));
  fireEvent.click(await screen.findByRole('button', { name: `Añadir ${product.name} al carrito` }));

  await waitFor(() => {
    expect(retailApi.addCartItem).toHaveBeenCalledWith(emptyCart.id, product.id, 1);
  });
  expect(await screen.findByText('1 × 2,35 €')).toBeInTheDocument();

  fireEvent.click(screen.getByRole('button', { name: 'Finalizar compra' }));

  expect(await screen.findByRole('heading', { name: '¡Tu cesta ya está en marcha!' })).toBeInTheDocument();
  expect(retailApi.createOrder).toHaveBeenCalledWith(emptyCart.id);
  expect(retailApi.getTracking).toHaveBeenCalledWith('ORDER-1');
  expect(screen.getByText('TRACK-1')).toBeInTheDocument();
  expect(screen.getByText(/Estado: en preparación/)).toBeInTheDocument();
  expect(screen.getByText(/El pedido sintético se está preparando para la demo/)).toBeInTheDocument();
});

test('shows a recoverable error when synthetic stores cannot load', async () => {
  (retailApi.getStores as jest.Mock).mockRejectedValueOnce(new Error('offline'));

  render(<App />);

  expect(await screen.findByText('No hemos podido cargar las tiendas sintéticas.')).toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: 'Reintentar' }));

  await waitFor(() => expect(retailApi.getStores).toHaveBeenCalledTimes(2));
  expect(await screen.findByText(store.name)).toBeInTheDocument();
});
