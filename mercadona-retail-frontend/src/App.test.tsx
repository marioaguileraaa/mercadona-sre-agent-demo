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
  expect(screen.queryByText(/Fictional technical SRE demo/)).not.toBeInTheDocument();
  expect(screen.getAllByText(/Demo técnica SRE ficticia/)).toHaveLength(2);
  expect(screen.getAllByText(/No es un sistema oficial de Mercadona/)).toHaveLength(2);
  expect(screen.getByRole('heading', { name: /Lo cotidiano/ })).toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Ver carrito, 0 productos' })).toBeDisabled();
});

test('selects a store, filters its catalog and handles an empty result', async () => {
  render(<App />);

  fireEvent.click(await screen.findByRole('button', { name: 'Comprar aquí' }));

  expect(await screen.findByText(product.name)).toBeInTheDocument();
  expect(retailApi.getProducts).toHaveBeenCalledWith(store.id);
  expect(retailApi.createCart).toHaveBeenCalledWith(store.id);
  expect(screen.getByRole('button', { name: 'Tienda seleccionada' })).toBeDisabled();
  expect(screen.getByRole('button', { name: 'Ver carrito, 0 productos' })).toBeEnabled();

  fireEvent.change(screen.getByRole('textbox', { name: 'Buscar productos sintéticos' }), {
    target: { value: 'sin coincidencias' },
  });

  expect(screen.getByRole('heading', { name: 'No encontramos coincidencias' })).toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: 'Ver todos los productos' }));
  expect(screen.getByText(product.name)).toBeInTheDocument();

  const allFilter = screen.getByRole('button', { name: 'Todo' });
  const produceFilter = screen.getByRole('button', { name: 'Fruta y verdura' });
  expect(allFilter).toHaveAttribute('aria-pressed', 'true');
  expect(produceFilter).toHaveAttribute('aria-pressed', 'false');
  fireEvent.click(produceFilter);
  expect(allFilter).toHaveAttribute('aria-pressed', 'false');
  expect(produceFilter).toHaveAttribute('aria-pressed', 'true');
});

test('adds through the cart API and completes checkout with tracking', async () => {
  const orderId = 'ORDER-1234567890abcdef1234567890abcdef';
  const trackingCode = 'TRACK-abcdef1234567890abcdef1234567890';
  (retailApi.addCartItem as jest.Mock).mockResolvedValue({
    cart: cartWithItem,
    correlationId: 'CORR-ADD',
  });
  (retailApi.createOrder as jest.Mock).mockResolvedValue({
    order: {
      id: orderId,
      cartId: emptyCart.id,
      storeId: store.id,
      status: 'Confirmado',
      trackingCode,
      createdAt: '2026-07-13T12:05:00Z',
      items: cartWithItem.items,
      total: product.price,
    },
    correlationId: 'CORR-ORDER',
  });
  (retailApi.getTracking as jest.Mock).mockResolvedValue({
    tracking: {
      orderId,
      trackingCode,
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
  expect(retailApi.getTracking).toHaveBeenCalledWith(orderId);
  expect(screen.getByText(orderId)).toBeInTheDocument();
  expect(screen.getByText(trackingCode)).toBeInTheDocument();
  expect(screen.getByText(/Estado: en preparación/)).toBeInTheDocument();
  expect(screen.getByText(/El pedido sintético se está preparando para la demo/)).toBeInTheDocument();
});

test('respects reduced-motion preferences when navigating between sections', async () => {
  const scrollIntoView = jest.fn();
  Object.defineProperty(HTMLElement.prototype, 'scrollIntoView', {
    configurable: true,
    value: scrollIntoView,
  });
  Object.defineProperty(window, 'matchMedia', {
    configurable: true,
    value: jest.fn().mockReturnValue({
      matches: true,
      media: '(prefers-reduced-motion: reduce)',
      onchange: null,
      addListener: jest.fn(),
      removeListener: jest.fn(),
      addEventListener: jest.fn(),
      removeEventListener: jest.fn(),
      dispatchEvent: jest.fn(),
    }),
  });

  render(<App />);
  fireEvent.click(await screen.findByRole('button', { name: 'Tiendas' }));

  expect(scrollIntoView).toHaveBeenCalledWith({ behavior: 'auto', block: 'start' });
});

test('shows a recoverable error when synthetic stores cannot load', async () => {
  (retailApi.getStores as jest.Mock).mockRejectedValueOnce(new Error('offline'));

  render(<App />);

  expect(await screen.findByText('No hemos podido cargar las tiendas sintéticas.')).toBeInTheDocument();
  fireEvent.click(screen.getByRole('button', { name: 'Reintentar' }));

  await waitFor(() => expect(retailApi.getStores).toHaveBeenCalledTimes(2));
  expect(await screen.findByText(store.name)).toBeInTheDocument();
});
