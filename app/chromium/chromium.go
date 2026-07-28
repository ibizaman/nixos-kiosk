package chromium

import (
	"context"
	"fmt"
	"time"

	"github.com/chromedp/chromedp"
)

func Navigate(port uint16, url string) error {
	ctx, cancel := chromedp.NewRemoteAllocator(
		context.Background(),
		fmt.Sprintf("http://localhost:%d", port),
	)
	defer cancel()

	ctx, cancel = chromedp.NewContext(ctx)
	defer cancel()

	ctx, cancel = context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	return chromedp.Run(ctx,
		chromedp.Navigate(url),
	)
}
