import { useEffect, useMemo, useState } from 'react';
import {
  Alert,
  AppBar,
  Box,
  Button,
  Card,
  CardActions,
  CardContent,
  Chip,
  CircularProgress,
  Container,
  CssBaseline,
  Grid,
  Paper,
  Stack,
  ThemeProvider,
  Toolbar,
  Typography,
  createTheme,
} from '@mui/material';
import AddShoppingCartIcon from '@mui/icons-material/AddShoppingCart';
import CheckCircleIcon from '@mui/icons-material/CheckCircle';
import Inventory2OutlinedIcon from '@mui/icons-material/Inventory2Outlined';
import LocationOnOutlinedIcon from '@mui/icons-material/LocationOnOutlined';
import ShoppingCartCheckoutIcon from '@mui/icons-material/ShoppingCartCheckout';
import { retailApi } from './services/api';
import { Cart, Order, Product, Store, Tracking } from './types';
import './App.css';

const disclaimer =
  'Fictional technical SRE demo. Not an official Mercadona system. All stores, products, prices, carts, orders, correlation IDs and metrics are synthetic; no claims about real operations.';

const theme = createTheme({
  palette: {
    primary: { main: '#126B3A', contrastText: '#FFFFFF' },
    secondary: { main: '#F2C94C', contrastText: '#1F2A24' },
    background: { default: '#F7FAF5', paper: '#FFFFFF' },
    text: { primary: '#1F2A24', secondary: '#4F5F56' },
  },
  typography: {
    fontFamily: '"Segoe UI", Arial, sans-serif',
    h1: { fontWeight: 800 },
    h2: { fontWeight: 750 },
    button: { fontWeight: 700, textTransform: 'none' },
  },
  shape: { borderRadius: 12 },
});

function App() {
  const [stores, setStores] = useState<Store[]>([]);
  const [products, setProducts] = useState<Product[]>([]);
  const [selectedStore, setSelectedStore] = useState<Store>();
  const [cart, setCart] = useState<Cart>();
  const [order, setOrder] = useState<Order>();
  const [tracking, setTracking] = useState<Tracking>();
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('Choose a synthetic store to begin.');
  const [error, setError] = useState('');

  useEffect(() => {
    retailApi.getStores().then(setStores).catch(() => setError('Unable to load synthetic stores.'));
  }, []);

  const cartCount = useMemo(
    () => cart?.items.reduce((sum, item) => sum + item.quantity, 0) ?? 0,
    [cart],
  );
  const cartTotal = useMemo(
    () => cart?.items.reduce((sum, item) => sum + item.lineTotal, 0) ?? 0,
    [cart],
  );

  const chooseStore = async (store: Store) => {
    setBusy(true);
    setError('');
    try {
      const [nextProducts, cartResponse] = await Promise.all([
        retailApi.getProducts(store.id),
        retailApi.createCart(store.id),
      ]);
      setSelectedStore(store);
      setProducts(nextProducts);
      setCart(cartResponse.cart);
      setOrder(undefined);
      setTracking(undefined);
      setMessage(`Synthetic cart ready at ${store.name}.`);
    } catch {
      setError('Unable to start a synthetic cart.');
    } finally {
      setBusy(false);
    }
  };

  const addProduct = async (product: Product) => {
    if (!cart) return;
    setBusy(true);
    setError('');
    try {
      const response = await retailApi.addCartItem(cart.id, product.id, 1);
      setCart(response.cart);
      setMessage(`${product.name} added successfully. Correlation: ${response.correlationId}`);
    } catch {
      setError('The synthetic item could not be added.');
    } finally {
      setBusy(false);
    }
  };

  const checkout = async () => {
    if (!cart) return;
    setBusy(true);
    setError('');
    try {
      const orderResponse = await retailApi.createOrder(cart.id);
      const trackingResponse = await retailApi.getTracking(orderResponse.order.id);
      setOrder(orderResponse.order);
      setTracking(trackingResponse.tracking);
      setMessage(`Synthetic order created. Correlation: ${orderResponse.correlationId}`);
    } catch {
      setError('Checkout requires at least one synthetic item.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <ThemeProvider theme={theme}>
      <CssBaseline />
      <Alert severity="warning" square sx={{ position: 'sticky', top: 0, zIndex: 1300 }}>
        {disclaimer}
      </Alert>
      <AppBar position="static" elevation={0}>
        <Toolbar>
          <Typography variant="h6" component="div" sx={{ flexGrow: 1, fontWeight: 800 }}>
            Mercadona Reliability Lab
          </Typography>
          <Chip icon={<AddShoppingCartIcon />} label={`${cartCount} synthetic items`} color="secondary" />
        </Toolbar>
      </AppBar>
      <Box component="main" sx={{ py: 5 }}>
        <Container maxWidth="lg">
          <Stack spacing={4}>
            <Paper sx={{ p: { xs: 3, md: 5 }, background: 'linear-gradient(135deg, #FFFFFF 0%, #E6F2E9 100%)' }}>
              <Typography variant="overline" color="primary" sx={{ fontWeight: 800 }}>
                Synthetic Azure SRE Agent scenario
              </Typography>
              <Typography variant="h2" component="h1" sx={{ mt: 1 }}>
                Grocery reliability, safely observable
              </Typography>
              <Typography color="text.secondary" sx={{ mt: 2, maxWidth: 760 }}>
                Walk through stores, products, cart, checkout and order tracking while a controlled,
                bounded memory-retention incident demonstrates investigation and Review-mode mitigation.
              </Typography>
            </Paper>

            {error && <Alert severity="error">{error}</Alert>}
            <Alert severity="info">{busy ? 'Processing synthetic request...' : message}</Alert>

            <Box>
              <Typography variant="h4" component="h2" gutterBottom>1. Stores</Typography>
              <Grid container spacing={2}>
                {stores.map((store) => (
                  <Grid size={{ xs: 12, md: 4 }} key={store.id}>
                    <Card variant={selectedStore?.id === store.id ? 'elevation' : 'outlined'}>
                      <CardContent>
                        <LocationOnOutlinedIcon color="primary" />
                        <Typography variant="h6">{store.name}</Typography>
                        <Typography color="text.secondary">{store.area}</Typography>
                        <Typography variant="body2" sx={{ mt: 1 }}>{store.fulfilmentNote}</Typography>
                      </CardContent>
                      <CardActions>
                        <Button onClick={() => chooseStore(store)} disabled={busy}>Shop this store</Button>
                      </CardActions>
                    </Card>
                  </Grid>
                ))}
              </Grid>
            </Box>

            {selectedStore && (
              <Box>
                <Typography variant="h4" component="h2" gutterBottom>2. Products</Typography>
                <Grid container spacing={2}>
                  {products.map((product) => (
                    <Grid size={{ xs: 12, sm: 6, md: 3 }} key={product.id}>
                      <Card variant="outlined" sx={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
                        <CardContent sx={{ flexGrow: 1 }}>
                          <Inventory2OutlinedIcon color="primary" />
                          <Typography variant="h6">{product.name}</Typography>
                          <Chip label={product.category} size="small" sx={{ my: 1 }} />
                          <Typography>{product.price.toFixed(2)} EUR / {product.unit}</Typography>
                        </CardContent>
                        <CardActions>
                          <Button
                            startIcon={<AddShoppingCartIcon />}
                            onClick={() => addProduct(product)}
                            disabled={busy}
                          >
                            Add
                          </Button>
                        </CardActions>
                      </Card>
                    </Grid>
                  ))}
                </Grid>
              </Box>
            )}

            {cart && (
              <Paper sx={{ p: 3 }}>
                <Typography variant="h4" component="h2">3. Shopping cart</Typography>
                <Stack spacing={1} sx={{ my: 2 }}>
                  {cart.items.length === 0 && <Typography color="text.secondary">Cart is empty.</Typography>}
                  {cart.items.map((item) => (
                    <Box key={item.productId} sx={{ display: 'flex', justifyContent: 'space-between' }}>
                      <Typography>{item.name} x {item.quantity}</Typography>
                      <Typography>{item.lineTotal.toFixed(2)} EUR</Typography>
                    </Box>
                  ))}
                </Stack>
                <Typography variant="h6">Total: {cartTotal.toFixed(2)} EUR</Typography>
                <Button
                  variant="contained"
                  color="secondary"
                  startIcon={<ShoppingCartCheckoutIcon />}
                  onClick={checkout}
                  disabled={busy || cart.items.length === 0}
                  sx={{ mt: 2 }}
                >
                  Checkout synthetic order
                </Button>
              </Paper>
            )}

            {order && tracking && (
              <Alert icon={<CheckCircleIcon />} severity="success">
                Order {order.id} is {tracking.status.toLowerCase()}. Tracking {tracking.trackingCode}.
                {' '}{tracking.message}
              </Alert>
            )}
          </Stack>
        </Container>
      </Box>
      <Box component="footer" sx={{ p: 3, bgcolor: '#1F2A24', color: '#FFFFFF' }}>
        <Container maxWidth="lg">
          <Typography variant="body2">{disclaimer}</Typography>
        </Container>
      </Box>
      {busy && <CircularProgress size={24} sx={{ position: 'fixed', right: 24, bottom: 24 }} />}
    </ThemeProvider>
  );
}

export default App;
